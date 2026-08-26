import ApplicationServices
import Cocoa

/// AX 通知注册/反注册要跨进程 IPC,不能在主线程执行。
/// `@unchecked Sendable`:CF 引用和 refcon 都只读,由 AX 后台串行队列使用。
struct SwitcherAXNotificationSubscription: @unchecked Sendable {
    let observer: AXObserver
    let element: AXUIElement
    let notifications: [String]
    let refcon: UnsafeMutableRawPointer?

    func register() {
        for notification in notifications {
            AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
    }

    func unregister() {
        for notification in notifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }
}

/// 一个被切换器跟踪的 app。负责:
///   1. 拿到 app 的 AXUIElement (`AXUIElementCreateApplication`)
///   2. 订阅 app 级别的 AX 通知(窗口创建、focus 变化、隐藏/显示)
///   3. 提供给上层枚举该 app 当前 AX windows 的能力
///
/// 由 `SwitcherWindowList` 拥有,生命周期跟随 NSRunningApplication。
///
/// `@unchecked Sendable`:`runningApplication` 和 `axUiElement` 是 immutable
/// 的,可变属性都受 `lock` 保护或者只在主线程写。
final class SwitcherApp: @unchecked Sendable {
    let runningApplication: NSRunningApplication
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?

    /// App 级 AXUIElement。所有 app 级别属性(windows、frontmost、focused window)
    /// 都从这里读。
    let axUiElement: AXUIElement

    /// 我们订阅 axObserver 的通知列表 —— 这些事件触发后,清单需要 re-sync。
    static let observedNotifications: [String] = [
        kAXApplicationActivatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    /// 在 AXObserver 回调里要用,所以做成 instance 字段。主线程负责挂载
    /// runloop source,通知注册走 AX 后台队列;`stopObserving` 显式解绑 source。
    private(set) var axObserver: AXObserver?

    /// 主线程读写 —— 用于 MRU 排序时记住"这个 app 是不是当前最前台"。
    var isHidden: Bool

    init(_ runningApplication: NSRunningApplication) {
        self.runningApplication = runningApplication
        self.pid = runningApplication.processIdentifier
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.localizedName = runningApplication.localizedName
        self.isHidden = runningApplication.isHidden
        self.axUiElement = AXUIElementCreateApplication(pid)
        // 元素级超时(只影响这一个元素,不动进程全局值),给窗口枚举留够预算 ——
        // 进程全局被压到 0.1s 是为了手势命中测试快速失败,对 kAXWindows 太紧。
        AXUIElementSetMessagingTimeout(axUiElement, AXCallQueue.appMessagingTimeout)
    }

    /// 是不是我们应该跟踪的 app。后台 daemon / agent / prohibited app 我们不管。
    var isEligibleForTracking: Bool {
        switch runningApplication.activationPolicy {
        case .regular: return true
        case .accessory, .prohibited: return false
        @unknown default: return false
        }
    }

    /// 装上 AXObserver。要求在主线程调用 —— `CFRunLoopAddSource` 需要 main
    /// runloop;可能阻塞的通知注册提交给 AX 后台串行队列。多次调用是幂等的。
    @MainActor
    func startObserving(_ callback: AXObserverCallback, _ refcon: UnsafeMutableRawPointer?) {
        guard axObserver == nil else { return }
        var observer: AXObserver?
        let createResult = AXObserverCreate(pid, callback, &observer)
        guard createResult == .success, let observer else { return }
        self.axObserver = observer

        // 把 observer 的 runloop source 挂到 main runloop common modes。
        // 这是 alt-tab 用 .accessibilityEventsThread 单独跑;我们 P1 直接走主
        // runloop —— AX 回调本身轻量(只是 dispatch 到队列),不会阻塞。
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        // 注册是跨进程 IPC,目标 app 启动中时可能卡住数百毫秒;不能占住负责
        // 弹出切换面板的主线程。紧随其后的首次窗口扫描走同一串行队列。
        let subscription = SwitcherAXNotificationSubscription(
            observer: observer,
            element: axUiElement,
            notifications: Self.observedNotifications,
            refcon: refcon
        )
        AXCallQueue.shared.submit {
            subscription.register()
        }
    }

    /// 释放 AXObserver。重要:不释放的话,每个曾经被跟踪过的 app 都会在 main
    /// runloop 留一个孤儿 source,一直涨内存(alt-tab issue #5612)。
    @MainActor
    func stopObserving() {
        guard let observer = axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = nil
    }

    /// 拿这个 app 当前所有 AXWindow。**只能在后台线程调** —— AX 调用会阻塞。
    /// nil 表示 AX 不响应或返回了空,调用方应当稍后重试。
    ///
    /// 两条管线合并:
    ///   - **标准路径** `kAXWindowsAttribute`:拿当前 Space 的窗口,快(1 次 IPC)。
    ///   - **暴力枚举** `_AXUIElementCreateWithRemoteToken`:能拿到**其他 Space**
    ///     的窗口,但要遍历最多 1000 个 element id,慢(~100ms 上限)。
    ///
    /// 公开 AX API 没有"拿一个进程所有桌面上所有窗口"的方法 —— 必须叠这两层。
    /// alt-tab `AXUIElement.allWindows(pid:)` 的同款 trick。
    ///
    /// `includeBruteForce` 默认 false —— 高频事件(activate / title / focus)只走
    /// 标准路径(目标 Space 的窗口即可),省掉 100ms 暴力枚举的代价。只在(a)
    /// 首次 addApp 和(b)kAXWindowCreatedNotification(新窗口有可能开在别的
    /// Space 上)这两个时机付费。
    nonisolated func copyAxWindows(includeBruteForce: Bool = false) -> [AXUIElement]? {
        var stdValue: CFTypeRef?
        let stdResult = AXUIElementCopyAttributeValue(axUiElement, kAXWindowsAttribute as CFString, &stdValue)
        let stdWindows: [AXUIElement] = (stdResult == .success ? (stdValue as? [AXUIElement]) : nil) ?? []
        let bruteWindows = includeBruteForce ? Self.windowsByBruteForce(pid: pid) : []
        let combined = stdWindows + bruteWindows
        // 标准调用失败 + 暴力没拿到 → 视为 AX 不响应,nil 让调用方稍后重试
        if combined.isEmpty && stdResult != .success { return nil }
        // 用 AxRef 包一层去重(AXUIElement 本身没 Hashable)
        return Array(Set(combined.map { AxRef(element: $0) })).map(\.element)
    }

    /// 暴力枚举:对 axUiElementId ∈ [0, 1000) 调
    /// `_AXUIElementCreateWithRemoteToken` 构造 AXUIElement,通过 subrole
    /// 过滤出真窗口。上限 100ms,到点就停 —— 即使有些窗口漏拿,下次 sync
    /// 还会再扫,丢失一两次不影响最终一致性。
    nonisolated private static func windowsByBruteForce(pid: pid_t) -> [AXUIElement] {
        var remoteToken = Data(count: 20)
        var pidValue = pid
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: &pidValue) { Data($0) })
        // bytes 4..8 = 0(Data 初始就是 0,不用动)
        var magic: Int32 = 0x636f636f   // "coco"
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: &magic) { Data($0) })

        let standardSubrole = kAXStandardWindowSubrole as String
        let dialogSubrole = kAXDialogSubrole as String
        var results: [AXUIElement] = []
        let startTime = CFAbsoluteTimeGetCurrent()
        let timeoutSeconds: Double = 0.1

        for axElemId: AXUIElementID in 0..<1000 {
            var idValue = axElemId
            remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: &idValue) { Data($0) })
            guard let unmanaged = _AXUIElementCreateWithRemoteToken(remoteToken as CFData) else { continue }
            let element = unmanaged.takeRetainedValue()
            // 只读 subrole;非窗口的 element 大概率不是 standard/dialog,直接过滤
            var subroleValue: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
            if r == .success,
               let subrole = subroleValue as? String,
               subrole == standardSubrole || subrole == dialogSubrole
            {
                results.append(element)
            }
            // 超时早退 —— 没扫完没关系,后续 sync 会接着补
            if CFAbsoluteTimeGetCurrent() - startTime > timeoutSeconds { break }
        }
        return results
    }
}

/// AXUIElement 没 Hashable;给个壳让 Set 能去重(用底层指针身份)。
private struct AxRef: Hashable {
    let element: AXUIElement
    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
    static func == (lhs: AxRef, rhs: AxRef) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
