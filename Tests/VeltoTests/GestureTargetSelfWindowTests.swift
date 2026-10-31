import AppKit
import SwiftUI
import Testing
@testable import Velto

@Test @MainActor func gestureTargetGuardRecognizesSelfOverlays() {
    let point = CGPoint(x: 100, y: 100)
    func window(pid: pid_t, level: NSWindow.Level = .normal,
                alpha: Double = 1, onscreen: Bool = true) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: level.rawValue,
         kCGWindowIsOnscreen as String: onscreen,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 200, height: 200).dictionaryRepresentation]
    }
    let other = window(pid: getpid() + 1)
    let normal = window(pid: getpid())
    let overlay = window(pid: getpid(), level: .screenSaver)
    // macOS 27 程序坞:layer 20、铺满全屏、鼠标穿透,压在所有普通窗口之上。
    let dock = window(pid: getpid() + 1, level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow))))
    for level in [NSWindow.Level.normal, .floating, .popUpMenu, .screenSaver] {
        #expect(GestureTargetController.topmostWindowIsSelf(
            in: [window(pid: getpid(), level: level), other], at: point))
    }
    #expect(!GestureTargetController.topmostWindowIsSelf(in: [other, normal], at: point))
    // 别家高层窗口可能穿透,挡不住下面的自己窗口;别家 layer 0 窗口才算挡住。
    #expect(GestureTargetController.topmostWindowIsSelf(in: [dock, normal, other], at: point))
    #expect(GestureTargetController.topmostWindowIsSelf(
        in: [window(pid: getpid() + 1, level: .screenSaver), overlay], at: point))
    #expect(!GestureTargetController.topmostWindowIsSelf(in: [dock, other, normal], at: point))
    #expect(!GestureTargetController.topmostWindowIsSelf(
        in: [window(pid: getpid(), level: .screenSaver, alpha: 0), other], at: point))
    #expect(!GestureTargetController.topmostWindowIsSelf(
        in: [window(pid: getpid(), level: .screenSaver, onscreen: false), other], at: point))
    #expect(!GestureTargetController.topmostWindowIsSelf(
        in: [overlay], at: CGPoint(x: 300, y: 300)))
    #expect(!GestureTargetController.topmostWindowIsSelf(in: [], at: point))
}

/// 使用真实截图视图与 WindowServer 列表,沿手势的后台 AX 查询入口验证不会回调 UI。
@Test @MainActor func gestureTargetLookupOverScreenshotReturnsSafely() async throws {
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.contentView = ScreenshotOverlayView(frame: .zero)
    let (target, _) = try await lookUpTargetFromBackground(over: window)
    #expect(target.pid == nil)
    #expect(target.window == nil)
}

/// 2026-09-29 闪退现场:普通层级的 SwiftUI 设置窗口被程序坞全屏窗口压着,守护失效,
/// 后台 AX 命中测试钻进 NSHostingView 求值主线程隔离的 Binding 闭包 → SIGTRAP。
@Test @MainActor func gestureTargetLookupOverSwiftUIWindowReturnsSelf() async throws {
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: BindingPickerProbe())
    let (target, isSelf) = try await lookUpTargetFromBackground(over: window)
    #expect(isSelf)
    #expect(target.pid == getpid())
}

private struct BindingPickerProbe: View {
    @State private var value = "a"
    var body: some View {
        MGMenuPicker(
            selection: Binding(get: { value }, set: { value = $0 }),
            options: [MGMenuOption("a", "A"), MGMenuOption("b", "B")]
        )
    }
}

/// 把窗口摆到主屏中央,等 WindowServer 列出后,在后台串行队列上做一次手势目标查询。
@MainActor private func lookUpTargetFromBackground(
    over window: NSWindow
) async throws -> (GestureExecutionTarget, isSelf: Bool) {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.main)
    window.setFrame(CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 100, width: 200, height: 200), display: true)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // WindowServer 在下一轮显示提交后才把新窗口列为 onscreen。别用固定 sleep 等:
    // 全量并行跑时这轮提交被主线程占用拖后,100ms 到点时列表里还没有它(实测并行
    // 跑连挂 4/4,串行跑全绿)。轮询到它出现为止。
    var rows: [[String: Any]] = []
    var listed: [String: Any]?
    for _ in 0..<60 where listed == nil {
        try await Task.sleep(for: .milliseconds(50))
        rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        listed = rows.first {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
        }
    }
    let row = try #require(listed)
    let bounds = try #require((row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)))
    let point = CGPoint(x: bounds.midX, y: bounds.midY)
    let isSelf = GestureTargetController.topmostWindowIsSelf(in: rows, at: point)
    let target = await withCheckedContinuation { continuation in
        DispatchQueue(label: "com.velto.test.gesture.target-lookup").async {
            continuation.resume(returning: GestureTargetController.executionTarget(
                at: point, policy: .windowUnderPointer, frontmostApplicationAtGestureStart: nil))
        }
    }
    return (target, isSelf)
}
