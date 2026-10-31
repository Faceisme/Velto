import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 能操作一个窗口的句柄。AX 拿得到窗口就用 AX;Telegram、微信、富途这类对 AX 零窗口
/// 暴露的 App 只能靠 WindowServer,选中和移动窗口都只要 wid,不需要目标 App 配合。
enum WindowHandle: @unchecked Sendable {
    case accessibility(AXUIElement)
    case windowServer(CGWindowID)
}

/// `@unchecked Sendable`:`AXUIElement` 是 CFType,SDK 没标 Sendable,但本结构
/// 都是不可变字段,实例创建后只读,跨线程传递没有竞争风险。
struct GestureExecutionTarget: @unchecked Sendable {
    let policy: GestureTargetPolicy
    let pid: pid_t?
    let restoresOriginalFrontmostApplication: Bool
    let deliveryDelay: TimeInterval
    /// `nil`:只定位到 App,没定位到窗口。
    let handle: WindowHandle?
    let prefersDirectWindowClose: Bool

    var window: AXUIElement? {
        if case .accessibility(let window) = handle {
            return window
        }
        return nil
    }

    fileprivate static func none(
        policy: GestureTargetPolicy = .windowUnderPointer,
        restoresOriginalFrontmostApplication: Bool = false
    ) -> GestureExecutionTarget {
        GestureExecutionTarget(
            policy: policy,
            pid: nil,
            restoresOriginalFrontmostApplication: restoresOriginalFrontmostApplication,
            deliveryDelay: 0,
            handle: nil,
            prefersDirectWindowClose: false
        )
    }
}

enum GestureTargetController {
    static func executionTarget(
        at point: CGPoint,
        policy: GestureTargetPolicy,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) -> GestureExecutionTarget {
        switch policy {
        case .activeWindow:
            return .none(
                policy: policy,
                restoresOriginalFrontmostApplication: frontmostApplicationAtGestureStart != nil
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

        switch target.handle {
        case .accessibility(let window):
            AXClient.focus(window: window, pid: pid)
        case .windowServer(let wid):
            // AX 熔断期 / AX 压根拿不到窗口:`activate` 只把 app 提到前台,
            // **选不中**具体那个窗口 —— 观感就是「窗口上来了却没被选中、像卡住」
            // (2026-08-27 Telegram 那次用户报的正是这个)。
            //
            // 走 WindowServer 直接把这个 wid 变成 key window:SLPS 只跟
            // WindowServer 说话,**一次 AX RPC 都不发给目标 app**,所以不违背
            // 熔断「别去打扰它主线程」的初衷。
            SwitcherFocus.raiseByWindowServer(pid: pid, cgWindowId: wid)
            WindowManagementDebugLog.log("  ↑ AX 无窗口 → WindowServer 选中 wid=\(wid) pid=\(pid)")
        case nil:
            break
        }
    }

    static func windowUnderPointer(at point: CGPoint) -> AXUIElement? {
        executionTarget(
            at: point,
            policy: .windowUnderPointer,
            frontmostApplicationAtGestureStart: nil
        ).window
    }

    static func maximizeWindowUnderPointer(at point: CGPoint) {
        guard let window = windowUnderPointer(at: point) else {
            return
        }

        maximizeWindow(window, containingEventLocation: point)
    }

    static func maximizeWindow(_ window: AXUIElement, containingEventLocation point: CGPoint) {
        let frame = DisplayCoordinateConverter.visibleFrame(containingEventLocation: point)
        guard !frame.isEmpty else {
            return
        }

        let ok = AXClient.setFrame(frame, ofWindow: window)
        if WindowManagementDebugLog.isEnabled {
            let result = AXClient.frame(of: window).map(fmt) ?? "?"
            WindowManagementDebugLog.log("最大化: 目标 frame=\(fmt(frame)) → 结果 frame=\(result) ok=\(ok)")
        }
    }

    private static func targetUnderPointer(at point: CGPoint) -> GestureExecutionTarget {
        let result = computeTargetUnderPointer(at: point)
        if WindowManagementDebugLog.isEnabled {
            logChosenTarget(point: point, result: result)
        }
        return result
    }

    private static func computeTargetUnderPointer(at point: CGPoint) -> GestureExecutionTarget {
        // CGWindowListCopyWindowInfo 是跨进程的全窗口枚举,本次手势内最多取一次,
        // 各个 fallback 路径复用同一份列表。这里**无条件**先取一次,因为接下来
        // 要先用它做 self-pid 守护(见 `WindowInfo.ownPid` 注释)。
        let snapshot = WindowSnapshot.onScreen()

        if WindowManagementDebugLog.isEnabled {
            logWindowStack(point: point, snapshot: snapshot)
        }

        // 置顶浮动窗口压在最上层 → 直接按 CGWindowList 定位,不做 AX 命中测试。
        // 后面各路径只认 layer 0,AX 明明命中了它也会被「以 CG 栈顶为准」校正走
        // (见 floatingWindowOnTop)。它的 wid、几何都在列表里,target(from:) 按 frame
        // 配 AX 窗口就够了;也就不用担心命中测试穿过它落进下面 Velto 自己的窗口。
        if let floating = snapshot.floatingWindowOnTop(at: point) {
            if WindowManagementDebugLog.isEnabled {
                WindowManagementDebugLog.log("  最上层是浮动窗口 layer=\(floating.layer) app=\"\(floating.ownerName)\" pid=\(floating.pid) → 直接按 CGWindowList 定位")
            }
            return target(from: floating)
        }

        // 鼠标下最上层是 Velto 自己时,**绝对**不能再调
        // AXUIElementCopyElementAtPosition —— 详见 `WindowInfo.ownPid` 注释。
        // 但仍要让 move/resize 对设置窗口本身生效,所以改走
        // "按 frame 匹配自己 app 的 AX 窗口列表"路径:AXUIElementCreateApplication +
        // kAXWindowsAttribute 枚举的是 NSApp.windows 快照,AppKit 内部 sync 回主线程
        // 读 NSWindow.frame,不会跑 SwiftUI hit-test,在 background queue 上安全。
        if snapshot.isOverOwnWindow(at: point) {
            if WindowManagementDebugLog.isEnabled {
                WindowManagementDebugLog.log("  最上层是 Velto 自己 → 只匹配自身窗口(self 守护路径)")
            }
            return snapshot.topmostOwnWindow(at: point).map(target(from:)) ?? .none()
        }

        let candidate = snapshot.topmostAppWindow(at: point)

        // 已熔断的 app(Telegram / 微信 / 富途这类对 AX 零窗口暴露的)直接跳过命中
        // 测试 —— 那次上限 0.1s 的同步 RPC 压的是它自己的主线程,而结果必然是 nil。
        if let candidate, AxDeadPids.isDead(candidate.pid) {
            if WindowManagementDebugLog.isEnabled {
                WindowManagementDebugLog.log("  ⏭️ pid=\(candidate.pid) app=\"\(candidate.ownerName)\" 已 AX 熔断 → 跳过命中测试,直接走 CGWindowList")
            }
            return target(from: candidate)
        }

        guard let element = AXClient.element(at: point) else {
            if WindowManagementDebugLog.isEnabled {
                WindowManagementDebugLog.log("  AX 命中失败(AXUIElementCopyElementAtPosition 返回 nil)→ 回退 CGWindowList")
            }
            // 这里**不熔断**:命中测试失败可能只是一次偶发超时,而熔断会让健康
            // app 的 ⌥ 拖拽降级 5 秒。紧接着的 target(from:) 会去查 kAXWindows,
            // 那个「success + 0 个窗口」才是 AX 哑巴的确定性信号,由它来记账。
            return candidate.map(target(from:)) ?? .none()
        }

        if WindowManagementDebugLog.isEnabled {
            let elemPid = AXClient.pid(of: element)
            WindowManagementDebugLog.log("  AX 命中: element pid=\(elemPid.map(String.init) ?? "?") app=\"\(elemPid.map { appName(forPid: $0, in: snapshot) } ?? "?")\" role=\(AXClient.role(of: element) ?? "?")")
        }

        let window = AXClient.windowElement(containing: element)
        if window == nil, let candidate {
            if WindowManagementDebugLog.isEnabled {
                WindowManagementDebugLog.log("  AX 命中元素找不到所属窗口 → 回退 CGWindowList: app=\"\(candidate.ownerName)\" pid=\(candidate.pid) frame=\(fmt(candidate.bounds))")
            }
            return target(from: candidate)
        }

        let pid = window.flatMap(AXClient.pid(of:)) ?? AXClient.pid(of: element)
        guard let pid else {
            return candidate.map(target(from:)) ?? .none()
        }

        // 【AX 命中的不是光标下的普通窗口时,以 CG 栈顶为准】
        // AX 命中会落在程序坞、后台 App 的 HUD 这类高层窗口上,这些不是手势该操作的
        // 目标(常规 App 的浮动窗口前面已经单独处理过)。CGWindowList 在光标点的栈顶
        // 才是用户看到的那个普通窗口(与 CGEvent 同坐标系,权威):AX 命中 pid 与栈顶
        // pid 不一致时,以栈顶为准。
        if let candidate, candidate.pid != pid {
            if WindowManagementDebugLog.isEnabled {
                WindowManagementDebugLog.log("  ⚠️ AX 命中 pid=\(pid) app=\"\(appName(forPid: pid, in: snapshot))\" 与 CG 栈顶 pid=\(candidate.pid) app=\"\(candidate.ownerName)\" 不一致 → 以 CG 栈顶为准")
            }
            return target(from: candidate)
        }

        let rawApp = NSRunningApplication(processIdentifier: pid)
        let app = AppQuirks.foregroundApplication(for: rawApp) ?? rawApp
        let policy = AppQuirks.policy(rawApp: rawApp, foregroundApp: app)

        return GestureExecutionTarget(
            policy: .windowUnderPointer,
            pid: pid,
            restoresOriginalFrontmostApplication: false,
            deliveryDelay: policy.deliveryDelay,
            handle: window.map(WindowHandle.accessibility),
            prefersDirectWindowClose: policy.prefersDirectWindowClose
        )
    }

    private static func target(from candidate: WindowInfo) -> GestureExecutionTarget {
        let rawApp = NSRunningApplication(processIdentifier: candidate.pid)
        let app = AppQuirks.foregroundApplication(for: rawApp) ?? rawApp
        let policy = AppQuirks.policy(rawApp: rawApp, foregroundApp: app, ownerName: candidate.ownerName)
        let window = axWindow(matching: candidate)
            ?? app.flatMap { foregroundApp in
                guard foregroundApp.processIdentifier != candidate.pid else { return nil }
                return axWindow(matching: candidate, pid: foregroundApp.processIdentifier)
            }
        let pid = window.flatMap(AXClient.pid(of:)) ?? candidate.pid
        // Velto 自己的窗口不走 WindowServer:拿不到 AX 窗口时只激活 App。
        let windowServer = candidate.isOwn ? nil : WindowHandle.windowServer(candidate.id)

        return GestureExecutionTarget(
            policy: .windowUnderPointer,
            pid: pid,
            restoresOriginalFrontmostApplication: false,
            deliveryDelay: policy.deliveryDelay,
            handle: window.map(WindowHandle.accessibility) ?? windowServer,
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
            AXClient.focus(window: window, pid: pid)
        }

        guard let closeButton = AXClient.element(kAXCloseButtonAttribute, of: window) else {
            return false
        }

        return AXClient.press(closeButton)
    }

    /// 光标下最上层窗口的 **CGWindowID + 几何**,不碰 AX。
    ///
    /// 给「AX 哑巴 app」的拖拽兜底用:Telegram / 微信 / 富途对 `kAXWindows` 恒返回
    /// 0 个窗口,拿不到 AX 句柄就 `AXUIElementSetAttributeValue(kAXPosition)` 无从谈起,
    /// ⌥ 拖窗口在这些 app 上**从来就没工作过**。改走 WindowServer 的 `SLSMoveWindow`
    /// 只需要 wid,不需要目标 app 配合。见 `WindowDragController`。
    static func cgWindowUnderPointer(at point: CGPoint) -> WindowInfo? {
        let snapshot = WindowSnapshot.onScreen()
        return snapshot.floatingWindowOnTop(at: point) ?? snapshot.topmostAppWindow(at: point)
    }

    private static func axWindow(matching candidate: WindowInfo, pid: pid_t? = nil) -> AXUIElement? {
        let targetPid = pid ?? candidate.pid
        // 距离匹配不上(bestDistance > 80)不算哑巴,那是几何问题,不熔断。
        guard let windows = AXClient.windows(
            ofPid: targetPid,
            markingEmptyAs: "手势目标定位:kAXWindows 无窗口"
        ) else { return nil }

        var bestWindow: AXUIElement?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for window in windows {
            guard let frame = AXClient.frame(of: window) else {
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

    private static func frameDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.minX - right.minX)
            + abs(left.minY - right.minY)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }

    private static func isCommandW(_ shortcut: Shortcut) -> Bool {
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(shortcut.modifierFlags))
        let shortcutFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        return shortcut.keyCode == VirtualKeyCode.w && flags.intersection(shortcutFlags) == .maskCommand
    }

    // MARK: - 调试日志(仅 WindowManagementDebugLog 开启时调用)

    private static func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
    private static func fmt(_ r: CGRect) -> String {
        "[\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))]"
    }

    private static func appName(forPid pid: pid_t, in snapshot: WindowSnapshot) -> String {
        snapshot.ownerName(of: pid) ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// 转储光标下的 layer-0 + 浮动层窗口栈(上→下序),含被尺寸/可见性
    /// 过滤的项,用来判断"光标下最上层到底是谁"——bug 的第一现场。
    private static func logWindowStack(point: CGPoint, snapshot: WindowSnapshot) {
        var lines: [String] = []
        for window in snapshot.windows where window.isAppWindow && window.bounds.contains(point) {
            var flags = ""
            if window.layer != 0 { flags += " [浮动 layer=\(window.layer)]" }
            if window.isOwn { flags += " [self]" }
            if !window.isOnscreen { flags += " [非onscreen]" }
            if window.alpha <= 0.01 { flags += " [透明]" }
            if window.bounds.width < 40 || window.bounds.height < 40 { flags += " [<40被滤]" }
            lines.append("      #\(lines.count) app=\"\(window.ownerName)\" pid=\(window.pid) frame=\(fmt(window.bounds)) alpha=\(String(format: "%.2f", window.alpha))\(flags)")
        }
        WindowManagementDebugLog.log(
            "目标定位 @ \(fmt(point)) 命中的 layer0+浮动层 窗口栈(上→下):\(lines.isEmpty ? " 无" : "\n" + lines.joined(separator: "\n"))")
    }

    private static func logChosenTarget(point: CGPoint, result: GestureExecutionTarget) {
        guard let pid = result.pid else {
            WindowManagementDebugLog.log("→ 最终目标 @ \(fmt(point)): 无(回退/未命中)")
            return
        }
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let frameText = result.window.flatMap(AXClient.frame(of:)).map(fmt) ?? "?"
        WindowManagementDebugLog.log(
            "→ 最终目标 @ \(fmt(point)): pid=\(pid) app=\"\(app)\" window=\(result.window == nil ? "nil" : "有") frame=\(frameText)")
    }
}
