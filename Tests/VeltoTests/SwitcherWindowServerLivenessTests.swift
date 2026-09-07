import CoreGraphics
import XCTest
@testable import Velto

/// 回归:CGWindowListCreateDescriptionFromArray 的 CFArray 编码。
/// 元素必须是 raw CGWindowID 位模式(指针槽),NSNumber 编码会静默返回空 ——
/// 2026-07-22 该错误让 prune 把全部活窗口误删、切换器彻底失效。
/// 本测试拿系统真实活窗口验证 helper 真能查到,防编码退化。
@MainActor
final class SwitcherWindowServerLivenessTests: XCTestCase {
    private func liveWids(limit: Int) -> [CGWindowID] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rows = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        return Array(rows.compactMap { row -> CGWindowID? in
            guard let n = row[kCGWindowNumber as String] as? NSNumber else { return nil }
            return CGWindowID(truncating: n)
        }.prefix(limit))
    }

    func testKnownWidsFindsLiveWindows() throws {
        let wids = liveWids(limit: 5)
        try XCTSkipIf(wids.isEmpty, "无 GUI 环境,没有活窗口可验证")
        let known = SwitcherWindowList.windowServerKnownWids(wids)
        // 活窗口必须全部被认出 —— NSNumber 编码错误时这里 known 为空
        XCTAssertEqual(known, Set(wids))
    }

    func testKnownWidsDropsDeadWid() throws {
        let wids = liveWids(limit: 2)
        try XCTSkipIf(wids.isEmpty, "无 GUI 环境")
        // 4_000_000_000 不可能是活 wid;活的照常返回,死的不在集合里
        let dead: CGWindowID = 4_000_000_000
        let known = SwitcherWindowList.windowServerKnownWids(wids + [dead])
        XCTAssertEqual(known, Set(wids))
        XCTAssertFalse(known.contains(dead))
    }

    func testEmptyInput() {
        XCTAssertTrue(SwitcherWindowList.windowServerKnownWids([]).isEmpty)
    }

    /// 在屏窗口(取自 onScreenOnly 列表)的在屏状态必须为 true ——
    /// 召唤时同步 un-ghost / ghost 判定都依赖这个真值。
    func testOnscreenStatesReportsOnscreenTrue() throws {
        let wids = liveWids(limit: 5)
        try XCTSkipIf(wids.isEmpty, "无 GUI 环境")
        let states = SwitcherWindowList.windowServerOnscreenStates(wids)
        for wid in wids {
            XCTAssertEqual(states[wid], true, "wid=\(wid) 来自 onScreenOnly 列表,在屏状态却不是 true")
        }
    }
}
