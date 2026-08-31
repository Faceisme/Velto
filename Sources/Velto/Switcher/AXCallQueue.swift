import ApplicationServices
import Foundation

/// 所有 AX 读取调用都过这里,绝不在主线程同步等。
///
/// 为什么:AX 调用底层是 RPC 到目标 app 的主线程,如果目标 app 卡了
/// (Electron 应用启动期、Adobe 全家桶、Xcode 跑大编译等等),AX 调用会
/// **挂到默认 6 秒** 才超时返回。alt-tab 把全局超时改成 1s 又自己上后台队列,
/// 我们这里做同样的事,但简化:
///   - 后台队列有界并发(见 backgroundConcurrency),同 key 之间仍严格串行
///   - 全局每次启动一次 AXUIElementSetMessagingTimeout 把 1s 超时设上
///   - schedule(key:) 同 key 节流:连续来的同 wid 事件只处理最新一个
///
/// `@unchecked Sendable`:内部用 NSLock 保护可变状态;Swift 看不出来。
final class AXCallQueue: @unchecked Sendable {
    static let shared = AXCallQueue()

    /// 后台扫描的并发槽位。AX 调用是**阻塞等目标 app 主线程**,不吃我们的 CPU,
    /// 所以串行只会让启动时的批量扫描线性叠加:暴力枚举去掉 id 上限后每个 app
    /// 稳定烧满预算,12 个 app 就是 12 × 50ms 全排队等。
    ///
    /// 取 4 而不是更大:每个卡死的 app 最长占一个槽 1s(appMessagingTimeout),
    /// 槽太多等于允许更多哑巴 app 同时压在目标进程主线程上 —— 那正是 AxDeadPids
    /// 要防的事。4 够覆盖启动批量,又留着退路。
    private static let backgroundConcurrency = 4

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Velto.Switcher.AXCallQueue"
        q.maxConcurrentOperationCount = AXCallQueue.backgroundConcurrency
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 确认切换(`SwitcherFocus.raise`)专用的独立队列。聚焦是用户松手后的直接动作,
    /// 不能排在后台窗口扫描 / 标题读取后面 —— 否则前面有卡住的 app AX 调用时,
    /// 会出现"松手后没切过去、过会儿才跳"。用更高 QoS,与后台读取物理隔离。
    private let focusQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Velto.Switcher.AXCallQueue.focus"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    /// 输入法切换上下文读取专用的独立队列。输入法决策是用户切 App / Tab 后的
    /// 直接体验,不能与 Switcher 后台窗口扫描(sync-/title-/focus-)共线 ——
    /// 后台扫描撞上无响应 app 时每个 AX 调用最长挂 1s,头阻塞会表现为
    /// "切到浏览器后输入法迟迟不切"。各通道内部仍串行,避免并发轰炸 AX framework。
    private let inputSourceQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Velto.AXCallQueue.inputSource"
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
        // 进程级 AX 默认超时是 6s,对交互路径太长。
        //
        // ⚠️ 传 systemWide = 设置**整个进程**的默认值(SDK 头文件原话),所以这里
        // 必须和 GestureTargetController 取同一个值,否则两边会互相覆盖:此前这里
        // 设 1.0s,而 GestureTargetController.elementAtPosition 每做一次命中测试就
        // 重设成 0.1s —— 结果第一次手势之后切换器就永久掉到 0.1s 预算,Telegram 那种
        // 单次 kAXWindows 实测 53ms 的 app 在负载下会假超时、窗口从切换器里掉出去。
        // 现在全局统一 0.1s(命中测试要的快速失败),真正需要更长预算的切换器改为
        // 在自己的 app 元素上单独设置 —— 那是元素级的,不污染全局。见 SwitcherApp。
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.processMessagingTimeout)
    }

    /// 进程全局 AX 消息超时。改这个值要连 `GestureTargetController.axMessagingTimeout`
    /// 一起改 —— 两处写的是同一个进程级开关。
    static let processMessagingTimeout: Float = 0.10

    /// 切换器对单个 app 的预算:枚举窗口比一次命中测试贵得多(Telegram 实测 53ms),
    /// 用全局那 0.1s 会误杀。元素级设置只影响这一个元素。
    static let appMessagingTimeout: Float = 1.0

    /// `key` 用来同窗口/同 app 的事件节流。`block` 抛错会被吞,只打日志。
    func schedule(_ key: String, _ block: @escaping @Sendable () throws -> Void) {
        enqueue(key, on: queue, block)
    }

    /// 输入法切换专用:同 key 节流语义同 `schedule`,但走独立队列,
    /// 不被 Switcher 后台扫描头阻塞。
    func scheduleInputSource(_ key: String, _ block: @escaping @Sendable () throws -> Void) {
        enqueue(key, on: inputSourceQueue, block)
    }

    private func enqueue(
        _ key: String,
        on target: OperationQueue,
        _ block: @escaping @Sendable () throws -> Void
    ) {
        let op = BlockOperation()
        // capture `op` weakly inside the closure to break the strong cycle that
        // would otherwise keep finished operations alive in the dictionary.
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, let op else { return }
            // 节流:被后来的同 key 顶掉就空跑退出。
            //
            // 为什么不用 `Operation.cancel()`(它原来就是这么做的):cancelled 的
            // operation 会**立即 finish 而不等自己的依赖**,于是挂在它后面的同 key
            // op 被提前放行,和还在执行的那个撞上 —— 队列改并发后实测 peak=2。
            // 改成字典身份判断:作废的 op 照样排在依赖链上,轮到它才秒退,链的
            // 串行性不被破坏。
            self.lock.lock()
            let isCurrent = self.pending[key] === op
            self.lock.unlock()
            guard isCurrent else { return }
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

        // 串行:同 key 意味着同一个 pid/wid,两路 `applyProbes` 乱序落到 MainActor
        // 就是窗口误删。串行队列时代这是白送的,并发队列必须自己挂依赖。
        if let previous {
            op.addDependency(previous)
        }

        op.completionBlock = { [weak self, weak op] in
            guard let self, let op else { return }
            self.lock.lock()
            // 只在 pending 里仍然是这个 op 时才清,免得把后来同 key 的 op 顶掉。
            if self.pending[key] === op {
                self.pending.removeValue(forKey: key)
            }
            self.lock.unlock()
        }

        target.addOperation(op)
    }

    /// 用于无需节流的一次性后台调用(初次全量扫描等)。
    func submit(_ block: @escaping @Sendable () throws -> Void) {
        queue.addOperation {
            do {
                try block()
            } catch {}
        }
    }

    /// 确认切换专用:走独立高优队列,不和后台索引读取共线。
    func submitFocus(_ block: @escaping @Sendable () throws -> Void) {
        focusQueue.addOperation {
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
