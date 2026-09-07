import XCTest
@testable import Velto

/// 回归:召唤路径提速改造(2026-07-22)。
///   1. SwitcherTilesLayout 抽出后的布局数学必须与原 rebuild 内联版一致;
///   2. minimumVisibleDuration=0 → 确认零延迟(快速 tap-tap 不再合并 session
///      切到第三个 app);乱序 latch(pendingConfirmMaxAge)语义保持。
final class SwitcherSummonLatencyTests: XCTestCase {

    // MARK: - 布局

    func testLayoutUnscaledGrid() {
        // 5 个 thumbnails(232x168),宽度只够 3 列 → 2 行,scale=1
        let l = SwitcherTilesLayout(
            count: 5, style: .thumbnails,
            maxSize: NSSize(width: 800, height: 2000), spacing: 8, inset: 24
        )
        XCTAssertEqual(l.perRow, 3)
        XCTAssertEqual(l.scale, 1)
        // fullW = 3*232 + 2*8 + 48 = 760;fullH = 2*168 + 8 + 48 = 392
        XCTAssertEqual(l.contentSize.width, 760, accuracy: 0.01)
        XCTAssertEqual(l.contentSize.height, 392, accuracy: 0.01)
        // 第 0 个:左上角;flipped→AppKit y = contentH - inset - tileH
        let f0 = l.frame(at: 0)
        XCTAssertEqual(f0.origin.x, 24, accuracy: 0.01)
        XCTAssertEqual(f0.origin.y, 392 - 24 - 168, accuracy: 0.01)
        // 第 4 个:第二行第二列
        let f4 = l.frame(at: 4)
        XCTAssertEqual(f4.origin.x, 24 + 232 + 8, accuracy: 0.01)
        XCTAssertEqual(f4.origin.y, 392 - 24 - 168 - 8 - 168, accuracy: 0.01)
    }

    func testLayoutScalesDownWhenOverHeight() {
        // 高度不够 → scale<1,内容尺寸等比缩小
        let l = SwitcherTilesLayout(
            count: 12, style: .thumbnails,
            maxSize: NSSize(width: 800, height: 300), spacing: 8, inset: 24
        )
        XCTAssertLessThan(l.scale, 1)
        XCTAssertLessThanOrEqual(l.contentSize.height, 300.01)
        XCTAssertLessThanOrEqual(l.contentSize.width, 800.01)
    }

    func testLayoutSingleWindow() {
        let l = SwitcherTilesLayout(
            count: 1, style: .appIcons,
            maxSize: NSSize(width: 2000, height: 2000), spacing: 8, inset: 24
        )
        XCTAssertEqual(l.perRow, 1)
        XCTAssertEqual(l.contentSize.width, 130 + 48, accuracy: 0.01)
    }

    // MARK: - 即时确认

    func testZeroMinVisibleConfirmsImmediately() {
        var s = SwitcherPanelVisibilityState(minimumVisibleDuration: 0)
        s.markShown(at: 100.0)
        XCTAssertEqual(s.confirmDelay(at: 100.001), 0)   // 刚显示就确认,零延迟
    }

    func testPendingConfirmLatchStillWorks() {
        var s = SwitcherPanelVisibilityState(minimumVisibleDuration: 0)
        // release 先于 trigger:几毫秒内的乱序 → 消费;超龄 → 丢弃
        s.noteConfirmBeforeSession(at: 100.0)
        XCTAssertTrue(s.consumePendingConfirmForShownSession(at: 100.05))
        s.noteConfirmBeforeSession(at: 100.0)
        XCTAssertFalse(s.consumePendingConfirmForShownSession(at: 101.0))
        // 消费是一次性的
        XCTAssertFalse(s.consumePendingConfirmForShownSession(at: 100.0))
    }
}
