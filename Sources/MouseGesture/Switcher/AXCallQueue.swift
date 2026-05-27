import ApplicationServices
import Foundation

/// 所有 AX 读取调用都过这里,绝不在主线程同步等。
///
/// 为什么:AX 调用底层是 RPC 到目标 app 的主线程,如果目标 app 卡了
/// (Electron 应用启动期、Adobe 全家桶、Xcode 跑大编译等等),AX 调用会
/// **挂到默认 6 秒** 才超时返回。alt-tab 把全局超时改成 1s 又自己上后台队列,
/// 我们这里做同样的事,但简化:
///   - 后台串行队列(避免并发轰炸 AX framework 自己的锁)
///   - 全局每次启动一次 AXUIElementSetMessagingTimeout 把 1s 超时设上
///   - schedule(key:) 同 key 节流:连续来的同 wid 事件只处理最新一个
///
/// `@unchecked Sendable`:内部用 NSLock 保护可变状态;Swift 看不出来。
final class AXCallQueue: @unchecked Sendable {
    static let shared = AXCallQueue()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "VibeGestures.Switcher.AXCallQueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 同 key 在 queue 上 pending 的 operation。新来的同 key 任务会先 cancel
    /// 老的;cancel 不一定真停(operation 可能已经 isExecuting),但至少不会
    /// 再额外排一个进去。
    private let lock = NSLock()
    private var pending: [String: Operation] = [:]

    private init() {
        // 进程级 AX 默认超时是 6s。改成 1s,让卡死的目标 app 不会拖死我们。
        // 注意这是个进程全局开关:GestureTargetController 等其他 AX 用户也会
        // 受影响 —— 不过 1s 仍然远比交互响应慢,实际是改善而不是退化。
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    /// `key` 用来同窗口/同 app 的事件节流。`block` 抛错会被吞,只打日志。
    func schedule(_ key: String, _ block: @escaping @Sendable () throws -> Void) {
        let op = BlockOperation()
        // capture `op` weakly inside the closure to break the strong cycle that
        // would otherwise keep finished operations alive in the dictionary.
        op.addExecutionBlock { [weak op] in
            if op?.isCancelled == true { return }
            do {
                try block()
            } catch {
                // AX 调用失败基本只有两种情况:目标 app 不响应(.cannotComplete)
                // 或者元素已销毁。两种都不致命,静默丢弃。
            }
        }

        lock.lock()
        let previous = pending[key]
        pending[key] = op
        lock.unlock()

        previous?.cancel()

        op.completionBlock = { [weak self, weak op] in
            guard let self, let op else { return }
            self.lock.lock()
            // 只在 pending 里仍然是这个 op 时才清,免得把后来同 key 的 op 顶掉。
            if self.pending[key] === op {
                self.pending.removeValue(forKey: key)
            }
            self.lock.unlock()
        }

        queue.addOperation(op)
    }

    /// 用于无需节流的一次性后台调用(初次全量扫描等)。
    func submit(_ block: @escaping @Sendable () throws -> Void) {
        queue.addOperation {
            do {
                try block()
            } catch {}
        }
    }
}

/// AX 调用里我们用来表示"目标 app 不响应,可以重试"的错误。
enum SwitcherAxError: Error {
    case unresponsive
}

/// 把 AXError 包成 throw —— 调用点能用 try? 直接吞掉非致命错误。
@inline(__always)
func axThrowIfNotSuccess(_ result: AXError) throws {
    if result == .cannotComplete {
        throw SwitcherAxError.unresponsive
    }
    // .success 不抛;其他错误(.attributeUnsupported 等)也不抛,
    // 由调用点检查返回值。
}
