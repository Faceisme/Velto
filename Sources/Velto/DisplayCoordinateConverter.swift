import AppKit
import CoreGraphics
import Foundation

/// 全局坐标只有两套,差一次以**主屏高度**为轴的 y 翻转:
///
/// - Quartz:CGEvent、AX、CGWindowList、CGDisplayBounds。原点在主屏左上角,y 向下。
/// - AppKit:NSScreen、NSWindow。原点在主屏左下角,y 向上。
///
/// CGEvent 和 AX 本来就是同一套坐标,两者之间不需要换算。副屏在主屏左边或上边时,
/// 坐标会是负数或超过主屏高度,公式不变;翻转轴也不能换成桌面并集的高度。
enum DisplayCoordinateConverter {
    /// 一块屏幕的完整区域和可用区域(去掉菜单栏、程序坞),都是 AppKit 坐标。
    struct ScreenFrames: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private struct Desktop {
        let frame: NSRect
        let primaryHeight: CGFloat
    }

    private static let cacheLock = NSLock()
    // 通过 cacheLock 串行化,可以安全跨线程访问。
    nonisolated(unsafe) private static var cachedDesktop: Desktop?
    nonisolated(unsafe) private static var didRegisterScreenObserver = false

    // MARK: - 纯换算

    /// 翻转对两个方向都适用:Quartz → AppKit 和 AppKit → Quartz 是同一个公式。
    static func flipped(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 手势轨迹窗口铺满桌面并集,视图不翻转,视图原点就是并集的左下角。
    static func overlayPoint(
        fromEventLocation point: CGPoint,
        desktopFrame: CGRect,
        primaryHeight: CGFloat
    ) -> CGPoint {
        let appKit = flipped(point, primaryHeight: primaryHeight)
        return CGPoint(x: appKit.x - desktopFrame.minX, y: appKit.y - desktopFrame.minY)
    }

    /// 包含这个 Quartz 点的屏幕的可用区域,返回 Quartz 坐标。按完整区域找屏幕:光标在
    /// 菜单栏或程序坞上时不在可用区域里,但仍然属于这块屏幕。哪块都不在时用主屏。
    static func visibleFrame(
        containing point: CGPoint,
        screens: [ScreenFrames],
        primaryHeight: CGFloat
    ) -> CGRect {
        let screen = screens.first { flipped($0.frame, primaryHeight: primaryHeight).contains(point) }
            ?? screens.first
        return screen.map { flipped($0.visibleFrame, primaryHeight: primaryHeight) } ?? .zero
    }

    // MARK: - 当前屏幕布局

    static func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        flipped(rect, primaryHeight: desktop().primaryHeight)
    }

    static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        flipped(rect, primaryHeight: desktop().primaryHeight)
    }

    static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        flipped(point, primaryHeight: desktop().primaryHeight)
    }

    static func eventLocationToOverlayPoint(_ point: CGPoint) -> CGPoint {
        let desktop = desktop()
        guard !desktop.frame.isEmpty else {
            return point
        }

        return overlayPoint(fromEventLocation: point, desktopFrame: desktop.frame, primaryHeight: desktop.primaryHeight)
    }

    static func visibleFrame(containingEventLocation point: CGPoint) -> CGRect {
        let screens = NSScreen.screens.map { ScreenFrames(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        return visibleFrame(containing: point, screens: screens, primaryHeight: screens.first?.frame.height ?? 0)
    }

    static func prewarm() {
        _ = desktop()
        _ = visibleFrame(containingEventLocation: .zero)
    }

    static func desktopFrame() -> NSRect {
        desktop().frame
    }

    private static func desktop() -> Desktop {
        registerScreenObserverIfNeeded()

        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cachedDesktop {
            return cachedDesktop
        }

        let screens = NSScreen.screens
        let desktop = Desktop(
            frame: screens.reduce(NSRect.zero) { partial, screen in
                partial.union(screen.frame)
            },
            // screens 第一块永远是主屏,原点在 (0, 0)。
            primaryHeight: screens.first?.frame.height ?? 0
        )

        cachedDesktop = desktop
        return desktop
    }

    private static func registerScreenObserverIfNeeded() {
        cacheLock.lock()
        guard !didRegisterScreenObserver else {
            cacheLock.unlock()
            return
        }
        didRegisterScreenObserver = true
        cacheLock.unlock()

        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            invalidateDesktopCache()
        }
    }

    private static func invalidateDesktopCache() {
        cacheLock.lock()
        cachedDesktop = nil
        cacheLock.unlock()
    }
}
