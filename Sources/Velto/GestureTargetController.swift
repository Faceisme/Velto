import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `@unchecked Sendable`:`AXUIElement` 是 CFType,SDK 没标 Sendable,但本结构
/// 都是不可变字段,实例创建后只读,跨线程传递没有竞争风险。
struct GestureExecutionTarget: @unchecked Sendable {
    let policy: GestureTargetPolicy
    let pid: pid_t?
    let restoresOriginalFrontmostApplication: Bool
    let deliveryDelay: TimeInterval
    let window: AXUIElement?
    let prefersDirectWindowClose: Bool
}

enum GestureTargetController {
    private struct WindowCandidate {
        let pid: pid_t
        let ownerName: String
        let bounds: CGRect
    }

    struct TitleBarTarget: @unchecked Sendable {
        let window: AXUIElement
        let pid: pid_t?
        let ownerName: String
        let frame: CGRect
        let source: String

        var debugSummary: String {
            let pidText = pid.map(String.init) ?? "-"
            return "source=\(source) pid=\(pidText) app=\"\(ownerName)\" frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        }
    }

    /// Velto 自己的 pid。所有"鼠标下的目标"查询都必须先 skip 这个 pid ——
    /// 否则当鼠标停在 Velto 设置窗口边缘时(典型场景:用户 resize 设置窗口),
    /// `AXUIElementCopyElementAtPosition` 会被 AppKit 同步路由回我们自己的
    /// NSHostingView,在 *调用方所在线程*(可能是 WindowDragController 的
    /// background queue)同步跑 SwiftUI view graph update,撞到 MainActor
    /// 隔离的 Binding 闭包时 Swift 6 runtime executor 校验直接 SIGTRAP。
    private static let selfPid: pid_t = getpid()

    static func executionTarget(
        at point: CGPoint,
        policy: GestureTargetPolicy,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) -> GestureExecutionTarget {
        switch policy {
        case .activeWindow:
            if frontmostApplicationAtGestureStart != nil {
                return GestureExecutionTarget(
                    policy: policy,
                    pid: nil,
                    restoresOriginalFrontmostApplication: true,
                    deliveryDelay: 0,
                    window: nil,
                    prefersDirectWindowClose: false
                )
            }

            return GestureExecutionTarget(
                policy: policy,
                pid: nil,
                restoresOriginalFrontmostApplication: false,
                deliveryDelay: 0,
                window: nil,
                prefersDirectWindowClose: false
            )

        case .windowUnderPointer:
            return targetUnderPointer(at: point)
        }
    }

    static func restoreFrontmostApplication(_ application: NSRunningApplication?) {
        guard let application,
              !application.isTerminated else {
            return
        }

        application.activate(options: [.activateAllWindows])
    }

    static func prepareForExecution(_ target: GestureExecutionTarget) {
        guard target.policy == .windowUnderPointer,
              let pid = target.pid else {
            return
        }

        let rawApp = NSRunningApplication(processIdentifier: pid)
        let app = AppQuirks.foregroundApplication(for: rawApp) ?? rawApp
        app?.activate(options: [.activateAllWindows])

        if let window = target.window {
            focus(window: window, pid: pid)
        }
    }

    static func windowUnderPointer(at point: CGPoint) -> AXUIElement? {
        executionTarget(
            at: point,
            policy: .windowUnderPointer,
            frontmostApplicationAtGestureStart: nil
        ).window
    }

    static func frame(ofWindow window: AXUIElement) -> CGRect? {
        frame(of: window)
    }

    static func setFrame(_ frame: CGRect, ofWindow window: AXUIElement) -> Bool {
        guard setSize(frame.size, ofWindow: window) else {
            return false
        }
        return setPosition(frame.origin, ofWindow: window)
    }

    static func maximizeWindowUnderPointer(at point: CGPoint) {
        guard let window = windowUnderPointer(at: point) else {
            return
        }

        maximizeWindow(window, containingEventLocation: point)
    }

    static func maximizeWindow(_ window: AXUIElement, containingEventLocation point: CGPoint) {
        let frame = DisplayCoordinateConverter.visibleAccessibilityFrame(containingEventLocation: point)
        guard !frame.isEmpty else {
            return
        }

        _ = setFrame(frame, ofWindow: window)
    }

    @discardableResult
    static func minimizeWindow(_ window: AXUIElement) -> Bool {
        runOnMainIfSelf(window) {
            if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                return true
            }
            guard let button = axElementAttribute(kAXMinimizeButtonAttribute, of: window) else {
                return false
            }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
    }

    @discardableResult
    static func closeWindow(_ window: AXUIElement) -> Bool {
        runOnMainIfSelf(window) {
            guard let button = axElementAttribute(kAXCloseButtonAttribute, of: window) else {
                return false
            }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
    }

    static func titleBarWindow(at point: CGPoint, titleBarHeight: CGFloat = 28) -> AXUIElement? {
        titleBarTarget(at: point, titleBarHeight: titleBarHeight)?.window
    }

    static func titleBarTarget(at point: CGPoint, titleBarHeight: CGFloat = 28) -> TitleBarTarget? {
        let candidatePoints = targetLookupPoints(for: point)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let cachedWindowList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

        if candidatePoints.contains(where: { topmostWindowIsSelf(in: cachedWindowList, at: $0) }) {
            for p in candidatePoints {
                guard let candidate = selfWindowCandidate(in: cachedWindowList, at: p),
                      isPointInTitleBarActivationBand(p, frame: candidate.bounds, bandHeight: titleBarHeight) else {
                    continue
                }
                let target = target(from: candidate)
                guard let window = target.window else { return nil }
                return TitleBarTarget(
                    window: window,
                    pid: target.pid ?? candidate.pid,
                    ownerName: candidate.ownerName,
                    frame: frame(ofWindow: window) ?? candidate.bounds,
                    source: "cg-self"
                )
            }
            return nil
        }

        for p in candidatePoints {
            guard let candidate = windowCandidate(in: cachedWindowList, at: p),
                  isPointInTitleBarActivationBand(p, frame: candidate.bounds, bandHeight: titleBarHeight) else {
                continue
            }
            let target = target(from: candidate)
            guard let window = target.window else { return nil }
            return TitleBarTarget(
                window: window,
                pid: target.pid ?? candidate.pid,
                ownerName: candidate.ownerName,
                frame: frame(ofWindow: window) ?? candidate.bounds,
                source: "cg"
            )
        }

        guard let window = windowUnderPointer(at: point),
              let frame = frame(ofWindow: window) else {
            return nil
        }
        let candidates = [point, DisplayCoordinateConverter.eventLocationToAccessibilityPoint(point)]
        for p in candidates where frame.contains(p) {
            if isPointInTitleBarActivationBand(p, frame: frame, bandHeight: titleBarHeight) {
                let pid = processIdentifier(for: window)
                let ownerName = pid
                    .flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
                    ?? ""
                return TitleBarTarget(
                    window: window,
                    pid: pid,
                    ownerName: ownerName,
                    frame: frame,
                    source: "ax"
                )
            }
        }
        return nil
    }

    static func isPointInTitleBarActivationBand(_ point: CGPoint, frame: CGRect, bandHeight: CGFloat) -> Bool {
        frame.contains(point) && point.y >= frame.minY && point.y - frame.minY <= bandHeight
    }

    private static func targetUnderPointer(at point: CGPoint) -> GestureExecutionTarget {
        let candidatePoints = targetLookupPoints(for: point)

        // CGWindowListCopyWindowInfo 是跨进程的全窗口枚举,本次手势内最多取一次,
        // 各个 fallback 路径复用同一份列表。这里**无条件**先取一次,因为接下来
        // 要先用它做 self-pid 守护(见 selfPid 注释)。
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let cachedWindowList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

        // 鼠标下最上层是 Velto 自己时,**绝对**不能再调
        // AXUIElementCopyElementAtPosition —— 详见 selfPid 注释。
        // 但仍要让 move/resize 对设置窗口本身生效,所以改走
        // "按 frame 匹配自己 app 的 AX 窗口列表"路径:AXUIElementCreateApplication +
        // kAXWindowsAttribute 枚举的是 NSApp.windows 快照,AppKit 内部 sync 回主线程
        // 读 NSWindow.frame,不会跑 SwiftUI hit-test,在 background queue 上安全。
        if candidatePoints.contains(where: { topmostWindowIsSelf(in: cachedWindowList, at: $0) }) {
            for p in candidatePoints {
                if let candidate = selfWindowCandidate(in: cachedWindowList, at: p) {
                    return target(from: candidate)
                }
            }
            return fallbackTarget()
        }

        func candidateFromWindowList() -> WindowCandidate? {
            for p in candidatePoints {
                if let candidate = windowCandidate(in: cachedWindowList, at: p) {
                    return candidate
                }
            }
            return nil
        }

        guard let element = firstElementAtPosition(candidatePoints) else {
            if let candidate = candidateFromWindowList() {
                return target(from: candidate)
            }

            return fallbackTarget()
        }

        let window = windowElement(containing: element)
        if window == nil, let candidate = candidateFromWindowList() {
            return target(from: candidate)
        }

        let pid = window.flatMap(processIdentifier(for:)) ?? processIdentifier(for: element)
        guard let pid else {
            if let candidate = candidateFromWindowList() {
                return target(from: candidate)
            }

            return GestureExecutionTarget(
                policy: .windowUnderPointer,
                pid: nil,
                restoresOriginalFrontmostApplication: false,
                deliveryDelay: 0,
                window: nil,
                prefersDirectWindowClose: false
            )
        }

        let rawApp = NSRunningApplication(processIdentifier: pid)
        let app = AppQuirks.foregroundApplication(for: rawApp) ?? rawApp
        let policy = AppQuirks.policy(rawApp: rawApp, foregroundApp: app)

        return GestureExecutionTarget(
            policy: .windowUnderPointer,
            pid: pid,
            restoresOriginalFrontmostApplication: false,
            deliveryDelay: policy.deliveryDelay,
            window: window,
            prefersDirectWindowClose: policy.prefersDirectWindowClose
        )
    }

    private static func target(from candidate: WindowCandidate) -> GestureExecutionTarget {
        let rawApp = NSRunningApplication(processIdentifier: candidate.pid)
        let app = AppQuirks.foregroundApplication(for: rawApp) ?? rawApp
        let policy = AppQuirks.policy(rawApp: rawApp, foregroundApp: app, ownerName: candidate.ownerName)
        let window = axWindow(matching: candidate)
            ?? app.flatMap { foregroundApp in
                guard foregroundApp.processIdentifier != candidate.pid else { return nil }
                return axWindow(matching: candidate, pid: foregroundApp.processIdentifier)
            }
        let pid = window.flatMap(processIdentifier(for:)) ?? candidate.pid

        return GestureExecutionTarget(
            policy: .windowUnderPointer,
            pid: pid,
            restoresOriginalFrontmostApplication: false,
            deliveryDelay: policy.deliveryDelay,
            window: window,
            prefersDirectWindowClose: policy.prefersDirectWindowClose
        )
    }

    static func performDirectWindowCloseIfAvailable(
        for target: GestureExecutionTarget,
        shortcut: Shortcut
    ) -> Bool {
        let isCommandW = isCommandW(shortcut)
        guard target.prefersDirectWindowClose,
              isCommandW,
              let window = target.window else {
            return false
        }

        if let pid = target.pid {
            focus(window: window, pid: pid)
        }

        guard let closeButton = axElementAttribute(kAXCloseButtonAttribute, of: window) else {
            return false
        }

        let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        return result == .success
    }

    private static func targetLookupPoints(for point: CGPoint) -> [CGPoint] {
        let accessibilityPoint = DisplayCoordinateConverter.eventLocationToAccessibilityPoint(point)
        guard point != accessibilityPoint else {
            return [point]
        }

        return [point, accessibilityPoint]
    }

    private static func firstElementAtPosition(_ points: [CGPoint]) -> AXUIElement? {
        for point in points {
            if let element = elementAtPosition(point) {
                return element
            }
        }
        return nil
    }

    /// 跨进程 AX 查询:遇到卡死 / 无响应的目标 App 可能长时间阻塞。给它设一个消息
    /// 超时,超时后调用快速失败(返回非 .success),上层回退到 frontmost App,避免
    /// detached task 长期挂住、最终晚回来补发旧手势。
    private static let axMessagingTimeout: Float = 0.10

    private static func elementAtPosition(_ point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        )

        guard result == .success else {
            return nil
        }
        return element
    }

    private static func windowCandidate(in windowList: [[String: Any]], at point: CGPoint) -> WindowCandidate? {
        for info in windowList {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let onscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  onscreen,
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.01,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 40,
                  bounds.height >= 40,
                  bounds.contains(point) else {
                continue
            }

            // Velto 自己的窗口不能当作目标 —— 上层 targetUnderPointer 已经守住
            // 了 AX 路径,这里是 fallback 路径的同等防线。
            let pid = pid_t(pidNumber.intValue)
            if pid == selfPid { continue }

            return WindowCandidate(
                pid: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                bounds: bounds
            )
        }

        return nil
    }

    /// `windowCandidate` 的 self-only 版本:用于"鼠标停在 Velto 自己窗口上"分支,
    /// 显式只匹配 selfPid 的窗口(普通 windowCandidate 会主动 skip selfPid 作防线)。
    private static func selfWindowCandidate(in windowList: [[String: Any]], at point: CGPoint) -> WindowCandidate? {
        for info in windowList {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let onscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  onscreen,
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.01,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  pid_t(pidNumber.intValue) == selfPid,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 40,
                  bounds.height >= 40,
                  bounds.contains(point)
            else { continue }

            return WindowCandidate(
                pid: selfPid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                bounds: bounds
            )
        }
        return nil
    }

    /// 鼠标位置最上层的可见窗口是否属于 Velto 自己。最上层 = windowList 第一个
    /// layer==0 / onscreen / alpha>0 / 包含 point 的条目;尺寸阈值不卡,
    /// 这里只关心"是不是我们"而不是"是不是可拖"。
    private static func topmostWindowIsSelf(in windowList: [[String: Any]], at point: CGPoint) -> Bool {
        for info in windowList {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let onscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  onscreen,
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point),
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }

            return pid_t(pidNumber.intValue) == selfPid
        }
        return false
    }

    private static func processIdentifier(for element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    private static func axWindow(matching candidate: WindowCandidate, pid: pid_t? = nil) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid ?? candidate.pid)
        guard let windows = axElementArrayAttribute(kAXWindowsAttribute, of: app) else {
            return nil
        }

        var bestWindow: AXUIElement?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for window in windows {
            guard let frame = frame(of: window) else {
                continue
            }

            let distance = frameDistance(frame, candidate.bounds)
            if distance < bestDistance {
                bestDistance = distance
                bestWindow = window

                if distance == 0 {
                    break
                }
            }
        }

        return bestDistance <= 80 ? bestWindow : nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        if let frame = frameFromMultipleAttributes(of: window) {
            return frame
        }

        guard let position = pointAttribute(kAXPositionAttribute, of: window),
              let size = sizeAttribute(kAXSizeAttribute, of: window) else {
            return nil
        }

        return CGRect(origin: position, size: size)
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
        guard processIdentifier(for: window) == selfPid else { return action() }
        if Thread.isMainThread { return action() }
        return withoutActuallyEscaping(action) { escapableAction in
            let box = UnsafeBox(value: escapableAction)
            return DispatchQueue.main.sync { box.value() }
        }
    }

    private static func frameFromMultipleAttributes(of window: AXUIElement) -> CGRect? {
        let attributes = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString
        ] as CFArray
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        guard result == .success,
              let values = values as? [Any],
              values.count == 2,
              CFGetTypeID(values[0] as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((values[0] as! AXValue), .cgPoint, &position),
              AXValueGetValue((values[1] as! AXValue), .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ name: String, of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func frameDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.minX - right.minX)
            + abs(left.minY - right.minY)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }

    private static func windowElement(containing element: AXUIElement) -> AXUIElement? {
        if role(of: element) == kAXWindowRole {
            return element
        }

        if let window = axElementAttribute(kAXWindowAttribute, of: element) {
            return window
        }

        if let topLevel = axElementAttribute(kAXTopLevelUIElementAttribute, of: element),
           role(of: topLevel) == kAXWindowRole {
            return topLevel
        }

        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let parent = current.flatMap({ axElementAttribute(kAXParentAttribute, of: $0) }) else {
                return nil
            }
            if role(of: parent) == kAXWindowRole {
                return parent
            }
            current = parent
        }

        return nil
    }

    private static func focus(window: AXUIElement, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func isCommandW(_ shortcut: Shortcut) -> Bool {
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(shortcut.modifierFlags))
        let shortcutFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        return shortcut.keyCode == VirtualKeyCode.w && flags.intersection(shortcutFlags) == .maskCommand
    }

    private static func fallbackTarget() -> GestureExecutionTarget {
        GestureExecutionTarget(
            policy: .windowUnderPointer,
            pid: nil,
            restoresOriginalFrontmostApplication: false,
            deliveryDelay: 0,
            window: nil,
            prefersDirectWindowClose: false
        )
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(kAXRoleAttribute, of: element) as? String
    }

    private static func axElementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func axElementArrayAttribute(_ name: String, of element: AXUIElement) -> [AXUIElement]? {
        guard let value = attribute(name, of: element),
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

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value
    }
}
