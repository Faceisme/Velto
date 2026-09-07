import Foundation
import Testing

/// 候选列表只列"能切过去的目标":当前正在用的那个不出现,第一格是最近用过的
/// 上一个 app。
///
/// 演进了两版 —— 原来是 MRU 直排 [当前, 上一个, ...] + initialSelection=1,
/// 真正的目标永远压在末尾;中间试过把当前 app 挪到末尾,结果用户在自己的 app 里
/// 按 ⌘Tab 找不到它,以为窗口没被识别到。现在直接不显示,想留在原地按 Esc。
///
/// 这两处必须配套:只去掉条目不改 initialSelection,反向 ⌘⇧Tab 会越界一格。
private func switcherSource(_ file: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let url = root.appendingPathComponent("Sources/Velto/Switcher/\(file)")
  return try String(contentsOf: url, encoding: .utf8)
}

@Test func snapshotDropsCurrentAppFromCandidates() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // 必须是 snapshot 的最后一道工序,且在 perApp 折叠之后 —— 折叠前首位是窗口
  // 粒度的,perApp 下去掉它仍会剩下同 app 的其他窗口顶上来。
  let range = try #require(source.range(of: "let collapsed = Self.collapsePerApp(partitioned, mode: prefs.groupBy)"))
  let tail = source[range.upperBound...].prefix(200)
  #expect(tail.contains("dropCurrent(collapsed"))

  let implRange = try #require(source.range(of: "private static func dropCurrent("))
  let impl = source[implRange.upperBound...].prefix(400)
  // 只对 MRU 排序生效;首位得真是前台 app;只剩一个时不许删空
  #expect(impl.contains("sortBy == .recentlyFocused"))
  #expect(impl.contains("current.application.pid == frontPid"))
  #expect(impl.contains("windows.count > 1"))
  #expect(impl.contains("Array(windows.dropFirst())"))
  // 挪到末尾那版的残留:去掉后不能再把它接回去
  #expect(!impl.contains("+ [current]"))
}

@Test func initialSelectionSpansWholeList() throws {
  let source = try switcherSource("SwitcherController.swift")
  let range = try #require(source.range(of: "let initialSelection"))
  let block = source[range.upperBound...].prefix(300)
  // 正向第一格、反向最后一格 —— 列表里已经没有当前 app,无需跳过任何一格
  #expect(block.contains("reverse ? snapshot.count - 1 : 0"))
  #expect(!block.contains("snapshot.count - 2"))
}
