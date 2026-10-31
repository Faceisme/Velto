import Foundation
import Testing

/// "焦点先于入列落地 → 提升丢失"的回归防护(源码断言风格,与本目录其他测试一致)。
///
/// 2026-10 事故:App Store 刚启动,focus 读(一次 AX 调用)比 sync 先回来,
/// promoteToMostRecent 查不到 wid 静默返回;窗口随后按新窗口排到 MRU 末尾,
/// 单窗口 app 再没有焦点变化把它提上来。点回 Claude 再 ⌘Tab,首选落到 iPhone 镜像。
///   1. focus 读到未入列的 wid → 记欠账(anchor = 当时的 MRU 首位),入列时补位
///   2. 前台 app 的第一个窗口入列 → 首位
///   3. 读不到焦点窗口且确为前台 → app 粒度提升;NSWorkspace 激活也触发焦点读取
private func switcherSource(_ file: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let url = root.appendingPathComponent("Sources/Velto/Switcher/\(file)")
  return try String(contentsOf: url, encoding: .utf8)
}

@Test func focusReadLandsThroughApplyFocusedWindow() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // focus 读的落地不能再直调 promoteToMostRecent —— 那条路查不到 wid 就丢
  let focus = try #require(source.range(of: "private func updateFocusedWindowMRU(pid: pid_t)"))
  let focusBody = source[focus.upperBound...].prefix(900)
  #expect(focusBody.contains("applyFocusedWindow(wid, pid: pid)"))
  #expect(!focusBody.contains("self?.promoteToMostRecent"))

  let apply = try #require(source.range(of: "private func applyFocusedWindow("))
  let body = source[apply.upperBound...].prefix(1200)
  #expect(body.contains("promoteToMostRecent(wid: wid)"))
  #expect(body.contains("pendingFocus[wid] = (pid, anchor, now)"))
  #expect(body.contains("syncWindowsForApp(pid: pid)"))
  #expect(body.contains("promoteAppToTop(pid: pid"))
}

@Test func newWindowPriorityPendingThenReAddThenFrontFirst() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  let range = try #require(source.range(of: "private func initialFocusOrder(forNew wid: CGWindowID, pid: pid_t) -> Int {"))
  let body = source[range.upperBound...].prefix(2000)
  // 两份记忆都要先取走,免得没命中的那份残留
  #expect(body.contains("let pending = pendingFocus.removeValue(forKey: wid)"))
  #expect(body.contains("let memory = recentlyRemovedOrders.removeValue(forKey: wid)"))
  let pending = try #require(body.range(of: "if let pending, pending.pid == pid"))
  let reAdd = try #require(body.range(of: "} else if let memory,"))
  let front = try #require(body.range(of: "} else if pid == frontmostPid,"))
  let tail = try #require(body.range(of: "return windows.count"))
  #expect(pending.lowerBound < reAdd.lowerBound)
  #expect(reAdd.lowerBound < front.lowerBound)
  #expect(front.lowerBound < tail.lowerBound)
  // 补位插在 anchor 当前的位置:焦点之后聚焦过的窗口排在它前面
  #expect(body.contains("pending.anchor.flatMap { windows[$0]?.lastFocusOrder } ?? 0"))
}

@Test func workspaceActivationReadsFocusAndReconcileSharesHelper() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  let range = try #require(source.range(of: "@objc private func workspaceDidActivateApp("))
  let body = source[range.upperBound...].prefix(700)
  #expect(body.contains("updateFocusedWindowMRU(pid: app.processIdentifier)"))
  let reconcile = try #require(source.range(of: "func reconcileFrontmostWithSystem() {"))
  #expect(source[reconcile.upperBound...].prefix(300).contains("promoteAppToTop(pid: front.processIdentifier"))
}
