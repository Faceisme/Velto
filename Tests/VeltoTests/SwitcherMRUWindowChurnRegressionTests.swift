import Foundation
import Testing

/// "A↔B 交替切换偶发切到 C"的回归防护(源码断言风格,与本目录其他测试一致)。
///
/// 根因:微信 4.x 周期性重建 AX 树 —— 主窗口 element 被销毁但 CG 窗口还活着,
/// 旧代码收到 destroy 通知直接删窗,当前前台窗口被踢出清单;重新扫回来时又被
/// 排到 MRU 末尾。四处防护:
///   1. destroy 通知先问 WindowServer wid 是否还在,活着就保留条目并重扫
///   2. 短期内删又加的窗口恢复被删前的 MRU 位,不排末尾
///   3. 同 wid 换新 AX element 时替换句柄并重挂窗口级通知
///   4. 空扫描(app 有已跟踪窗口但一个都没扫到)不允许一次 miss 就删
private func switcherSource(_ file: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let url = root.appendingPathComponent("Sources/Velto/Switcher/\(file)")
  return try String(contentsOf: url, encoding: .utf8)
}

@Test func destroyedElementVerifiesWindowServerBeforeRemoval() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // destroy 通知不得直接 removeWindow,必须走验尸路径
  let range = try #require(source.range(of: "case kAXUIElementDestroyedNotification:"))
  let handler = source[range.upperBound...].prefix(400)
  #expect(handler.contains("handleWindowElementDestroyed(window)"))
  #expect(!handler.contains("removeWindow(window)"))
  // 验尸用 WindowServer 权威判定,且不限 on-screen(最小化/其他 Space 也要查得到)
  #expect(source.contains("windowServerKnowsWindow"))
  #expect(source.contains("CGWindowListCreateDescriptionFromArray"))
}

@Test func reAddedWindowRestoresItsMRUOrder() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // 移除时记住 MRU 位,短期内加回来要恢复,不能无脑排末尾
  #expect(source.contains("rememberRemovedOrder(of: window)"))
  #expect(source.contains("initialFocusOrder(forNew: probe.wid)"))
  #expect(!source.contains("win.lastFocusOrder = windows.count"))
  #expect(source.contains("removedOrderTTL"))
}

@Test func staleAxElementGetsReplacedAndResubscribed() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // 同 wid 换 element:先反订阅旧的,换新,再订阅 —— 顺序必须如此
  // CG-only 兜底窗口(富途牛牛)没有真窗口 element,跳过换手;AX 窗口照旧
  let swap = try #require(source.range(of: "if !probe.isCgOnly, !CFEqual(existing.axUiElement, probe.axUiElement) {"))
  let block = source[swap.upperBound...].prefix(300)
  let unsub = try #require(block.range(of: "unsubscribeWindowNotifications(existing)"))
  let assign = try #require(block.range(of: "existing.axUiElement = probe.axUiElement"))
  #expect(unsub.lowerBound < assign.lowerBound)
  // 注意 "subscribe…" 是 "unsubscribe…" 的子串,必须限定在赋值之后再找
  #expect(block[assign.upperBound...].contains("subscribeWindowNotifications(existing)"))
  // 前提:句柄必须是可变的
  let windowSource = try switcherSource("SwitcherWindow.swift")
  #expect(windowSource.contains("var axUiElement: AXUIElement"))
}

@Test func emptyScanDowngradesAggressiveRemovalPolicy() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // 空扫描 + 仍有跟踪窗口 → explicit(阈值1)必须降级为 routine(阈值2)
  #expect(source.contains("if seenWids.isEmpty && !missed.isEmpty && effectivePolicy == .explicitWindowStateChange {"))
  #expect(source.contains("effectivePolicy = .routineScan"))
  #expect(source.contains("missState.recordMiss(using: effectivePolicy)"))
}

@Test func removalIsDebugLogged() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // 下次再出"窗口无声消失"必须能从日志直接看到谁删的
  let range = try #require(source.range(of: "private func removeWindow"))
  let body = source[range.upperBound...].prefix(400)
  #expect(body.contains("SwitcherDebugLog.log(\"removeWindow wid="))
}
