import ApplicationServices
import CoreGraphics
import Foundation

/// AX 访问的统一入口,集中处理三件事:
///
/// - **超时**:进程全局超时只设一次(`installProcessTimeout`)。要别的预算就用
///   `application(pid:timeout:)` 设在元素上,只影响这一个元素。
/// - **熔断**:`windows(ofPid:)` 先查 `AxDeadPids`,已熔断的 App 一次 RPC 都不发。
/// - **线程**:写 Velto 自己的窗口时切回主线程,见 `runOnMainIfSelf`。
///
/// 这里的读写都是同步跨进程调用,会逼目标 App 在主线程上应答,不能放到事件 tap 线程上。
enum AXClient {
    // MARK: - 超时

    /// 进程全局 AX 消息超时。默认 6s 对交互路径太长;命中测试要的是快速失败。
    static let processTimeout: Float = 0.10

    private static let processTimeoutInstalled: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), processTimeout)
    }()

    /// ⚠️ 传 systemWide 元素 = **设置整个进程的全局默认超时**(SDK 头文件明确写了:
    /// "Pass the system-wide accessibility object ... if you want to set the timeout
    /// globally for this process")。所以只能在这里设一次,不能每次命中测试都重设 ——
    /// 此前切换器设 1.0s、命中测试每次设 0.1s,第一次手势之后切换器就永久掉到 0.1s,
    /// Telegram 那种单次 kAXWindows 实测 53ms 的 app 在负载下会假超时。
    static func installProcessTimeout() {
        _ = processTimeoutInstalled
    }

    /// App 元素。`timeout` 只影响这一个元素,不动进程全局值。
    static func application(pid: pid_t, timeout: Float? = nil) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        if let timeout {
            AXUIElementSetMessagingTimeout(app, timeout)
        }
        return app
    }

    // MARK: - 读属性

    static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ attribute: String, of element: AXUIElement) -> String? {
        value(attribute, of: element) as? String
    }

    static func bool(_ attribute: String, of element: AXUIElement) -> Bool? {
        value(attribute, of: element) as? Bool
    }

    static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = value(attribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement]? {
        guard let value = value(attribute, of: element),
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }

        return (value as! [Any]).compactMap { item in
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else {
                return nil
            }
            return (item as! AXUIElement)
        }
    }

    static func url(_ attribute: String, of element: AXUIElement) -> URL? {
        let value = value(attribute, of: element)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// 一次读多个属性,比逐个读快很多。读失败的属性不在结果里。
    static func values(of element: AXUIElement, _ attributes: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &values
        )
        guard result == .success, let array = values as? [CFTypeRef] else {
            return [:]
        }
        var dict = [String: CFTypeRef]()
        for (i, key) in attributes.enumerated() where i < array.count {
            let v = array[i]
            // .axError 会被以 placeholder 形式返回,过滤掉
            if CFGetTypeID(v) == AXValueGetTypeID(),
               AXValueGetType(v as! AXValue) == .axError
            {
                continue
            }
            dict[key] = v
        }
        return dict
    }

    static func point(from value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let v = value as! AXValue
        guard AXValueGetType(v) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &point) ? point : nil
    }

    static func size(from value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let v = value as! AXValue
        guard AXValueGetType(v) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(v, .cgSize, &size) ? size : nil
    }

    static func role(of element: AXUIElement) -> String? {
        string(kAXRoleAttribute, of: element)
    }

    /// 只读 element 内部 token,不向 app 发消息,销毁的 element 也能拿到。
    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    /// 本进程内的查询,廉价。
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid = CGWindowID(0)
        let result = _AXUIElementGetWindow(element, &wid)
        guard result == .success, wid != 0 else { return nil }
        return wid
    }

    // MARK: - 窗口

    /// 这个进程的 AX 窗口。已熔断的 pid 直接返回 nil,不发 RPC。
    ///
    /// 给了 `markingEmptyAs` 时,空列表和读取失败都视为"这个 App 不暴露 AX 窗口",记入
    /// 熔断账本:Telegram 实测就是 success + 0 个窗口,而这 53ms 是白花的。
    static func windows(
        ofPid pid: pid_t,
        timeout: Float? = nil,
        markingEmptyAs source: String? = nil,
        read: (AXUIElement) -> [AXUIElement]? = { elements(kAXWindowsAttribute, of: $0) }
    ) -> [AXUIElement]? {
        guard !AxDeadPids.isDead(pid) else { return nil }

        let windows = read(application(pid: pid, timeout: timeout))
        if let source, windows?.isEmpty ?? true {
            AxDeadPids.mark(pid, source: source)
            return nil
        }
        return windows
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        let values = values(of: window, [kAXPositionAttribute, kAXSizeAttribute])
        if let origin = values[kAXPositionAttribute].flatMap(point(from:)),
           let size = values[kAXSizeAttribute].flatMap(size(from:)) {
            return CGRect(origin: origin, size: size)
        }

        guard let origin = value(kAXPositionAttribute, of: window).flatMap(point(from:)),
              let size = value(kAXSizeAttribute, of: window).flatMap(size(from:)) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// 系统级命中测试。目标 App 不支持时返回 nil,调用方回退到 CGWindowList。
    static func element(at point: CGPoint) -> AXUIElement? {
        installProcessTimeout()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &element
        )

        guard result == .success else {
            return nil
        }
        return element
    }

    /// 元素所属的窗口。
    static func windowElement(containing element: AXUIElement) -> AXUIElement? {
        if role(of: element) == kAXWindowRole {
            return element
        }

        if let window = self.element(kAXWindowAttribute, of: element) {
            return window
        }

        if let topLevel = self.element(kAXTopLevelUIElementAttribute, of: element),
           role(of: topLevel) == kAXWindowRole {
            return topLevel
        }

        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let parent = current.flatMap({ self.element(kAXParentAttribute, of: $0) }) else {
                return nil
            }
            if role(of: parent) == kAXWindowRole {
                return parent
            }
            current = parent
        }

        return nil
    }

    // MARK: - 写

    /// 尺寸 → 位置 → 再补一次尺寸。只设一次尺寸不够:app 会按窗口**当前**原点把
    /// 尺寸夹到屏幕内 —— 访达在 x=149 时设宽 1920,实际只给 1771(=1920−149),
    /// 再挪到 x=0 就成了"贴左但没铺满",得按第二次才满。挪完位置后再设一次尺寸,
    /// 这时原点已经对了,不会再被夹。先设一次尺寸是为了跨屏挪时大窗口不被位置推偏。
    static func setFrame(_ frame: CGRect, ofWindow window: AXUIElement) -> Bool {
        guard setSize(frame.size, ofWindow: window),
              setPosition(frame.origin, ofWindow: window) else {
            return false
        }
        return setSize(frame.size, ofWindow: window)
    }

    static func setPosition(_ position: CGPoint, ofWindow window: AXUIElement) -> Bool {
        runOnMainIfSelf(window) {
            var position = position
            guard let value = AXValueCreate(.cgPoint, &position) else { return false }
            return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        }
    }

    static func setSize(_ size: CGSize, ofWindow window: AXUIElement) -> Bool {
        runOnMainIfSelf(window) {
            var size = size
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
        }
    }

    /// 把窗口变成目标 App 的焦点窗口。
    static func focus(window: AXUIElement, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// 对 Velto 自己进程的 AX window 写入(setPosition/setSize)必须在 main thread:
    /// AppKit 的 `-[NSWindow _setFrameCommon:display:fromServer:]` 通过
    /// `NSWMWindowCoordinator performTransactionUsingBlock:` 内部断言主线程,
    /// 从 background queue 调直接 brk。这里只挑 self 走 main sync —— 不影响
    /// 其他 app 的窗口(那些走跨进程 AX,server 自己排队)。
    /// 用 `Thread.isMainThread` 兜底防止已在 main 上时 `DispatchQueue.main.sync`
    /// 死锁。
    /// `AXUIElement` 不 Sendable、闭包跨 queue 也会被 Swift 6 拦住,但这里只是
    /// 同步等 main 上跑完就返回,引用不会真的逃逸,用 `@unchecked Sendable` 包装
    /// 把 escape hatch 收敛在 helper 内部。
    private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

    private static func runOnMainIfSelf(_ window: AXUIElement, _ action: () -> Bool) -> Bool {
        guard pid(of: window) == WindowInfo.ownPid else { return action() }
        if Thread.isMainThread { return action() }
        return withoutActuallyEscaping(action) { escapableAction in
            let box = UnsafeBox(value: escapableAction)
            return DispatchQueue.main.sync { box.value() }
        }
    }
}
