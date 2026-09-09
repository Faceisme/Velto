import AppKit
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
    for level in [NSWindow.Level.normal, .floating, .popUpMenu, .screenSaver] {
        #expect(GestureTargetController.topmostWindowIsSelf(
            in: [window(pid: getpid(), level: level), other], at: point))
    }
    #expect(!GestureTargetController.topmostWindowIsSelf(in: [other, normal], at: point))
    #expect(!GestureTargetController.topmostWindowIsSelf(
        in: [window(pid: getpid() + 1, level: .screenSaver), overlay], at: point))
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
    _ = NSApplication.shared
    let screen = try #require(NSScreen.main)
    let frame = CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 100, width: 200, height: 200)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.contentView = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: frame.size))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // WindowServer 在下一轮显示提交后才把新窗口列为 onscreen。
    try await Task.sleep(for: .milliseconds(100))

    let rows = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
    let row = try #require(rows.first {
        ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
    })
    let bounds = try #require((row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)))
    let point = CGPoint(x: bounds.midX, y: bounds.midY)
    #expect(GestureTargetController.topmostWindowIsSelf(in: rows, at: point))
    let target = await withCheckedContinuation { continuation in
        DispatchQueue(label: "com.velto.test.gesture.target-lookup").async {
            continuation.resume(returning: GestureTargetController.executionTarget(
                at: point, policy: .windowUnderPointer, frontmostApplicationAtGestureStart: nil))
        }
    }
    #expect(target.pid == nil)
    #expect(target.window == nil)
}
