import ApplicationServices
import CoreGraphics
import XCTest
@testable import Velto

/// 回归:富途牛牛这类对 Accessibility 零窗口暴露的 app,靠 CGWindowList 兜底
/// 进切换器。这里只测行过滤纯函数 cgFallbackProbe —— 真窗口留下、噪音丢弃。
final class SwitcherCgFallbackProbeTests: XCTestCase {
    private let appElement = AXUIElementCreateApplication(getpid())
    private let pid: pid_t = 4242

    private func window(
        pid: pid_t = 4242,
        layer: Int = 0,
        name: String? = "富途牛牛",
        alpha: Double = 1.0,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1728, height: 1026)
    ) -> WindowInfo {
        WindowInfo(id: 100, pid: pid, name: name, layer: layer, bounds: bounds, alpha: alpha, isOnscreen: false)
    }

    private func probe(_ window: WindowInfo) -> SwitcherWindowProbe? {
        SwitcherWindowList.cgFallbackProbe(window: window, pid: pid, appElement: appElement)
    }

    func testKeepsRealTitledMainWindow() {
        let p = probe(window())
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.wid, 100)
        XCTAssertEqual(p?.title, "富途牛牛")
        XCTAssertTrue(p?.isCgOnly ?? false)
        XCTAssertEqual(p?.subrole, kAXStandardWindowSubrole as String)
    }

    func testDropsOtherApp() {
        XCTAssertNil(probe(window(pid: 9999)))
    }

    func testDropsLayersAboveFloating() {
        XCTAssertNil(probe(window(layer: 25)))          // 菜单/程序坞以上
    }

    /// 只认 layer 0 时,AX 哑巴 App 的置顶窗口会从切换器里消失(同 Movist 那类问题)。
    func testKeepsFloatingWindow() {
        XCTAssertNotNil(probe(window(layer: 3)))
    }

    func testDropsUntitledStrip() {
        XCTAssertNil(probe(window(name: "", bounds: CGRect(x: 0, y: 0, width: 1728, height: 33))))
        XCTAssertNil(probe(window(name: nil)))
    }

    func testDropsNearInvisibleAlpha() {
        XCTAssertNil(probe(window(name: "牛牛AI", alpha: 0.001)))
    }

    func testDropsTooSmall() {
        XCTAssertNil(probe(window(bounds: CGRect(x: 0, y: 0, width: 80, height: 40))))
    }

    func testTrimsWhitespaceTitle() {
        XCTAssertNil(probe(window(name: "   ")))
    }
}
