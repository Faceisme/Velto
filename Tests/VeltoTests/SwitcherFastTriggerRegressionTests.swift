import Foundation
import Testing

/// 快速 ⌘Tab 偶发不切换的三处修复的回归防护(源码断言风格,与本目录其他测试一致):
///   1. SwitcherKeyTapState.setActive(false) 不得清 hasQueuedTrigger
///   2. triggerOrCycle 的 step 分支必须先取消 pendingConfirmTask
///   3. MRU 更新用事件来源 pid;召唤前有 reconcileFrontmostWithSystem 同步校正
private func switcherSource(_ file: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let url = root.appendingPathComponent("Sources/Velto/Switcher/\(file)")
  return try String(contentsOf: url, encoding: .utf8)
}

@Test func keyTapDeactivationPreservesQueuedTrigger() throws {
  let source = try switcherSource("SwitcherKeyTap.swift")
  // setActive 里 hasQueuedTrigger 的清除必须被 active 条件保护
  #expect(source.contains("""
        if active {
            hasQueuedTrigger = false
        }
"""))
}

@Test func triggerCycleCancelsPendingConfirm() throws {
  let source = try switcherSource("SwitcherController.swift")
  // session 已活跃的 trigger(再次按下)要先作废旧的延迟确认再 step
  let range = try #require(source.range(of: "if SwitcherSession.isActive {"))
  let afterActiveCheck = source[range.upperBound...]
  let stepIdx = try #require(afterActiveCheck.range(of: "stepSelection(reverse: reverse)"))
  let cancelIdx = try #require(afterActiveCheck.range(of: "pendingConfirmTask?.cancel()"))
  #expect(cancelIdx.lowerBound < stepIdx.lowerBound)
}

@Test func pendingConfirmLatchHasExpiry() throws {
  let source = try switcherSource("SwitcherController.swift")
  #expect(source.contains("pendingConfirmMaxAge"))
  #expect(source.contains("noteConfirmBeforeSession(at:"))
  #expect(source.contains("consumePendingConfirmForShownSession(at:"))
}

@Test func mruUpdateUsesEventSourcePid() throws {
  let source = try switcherSource("SwitcherWindowList.swift")
  // 不允许再出现无参版本(隐式读 frontmostPid)
  #expect(!source.contains("updateFocusedWindowMRU()"))
  #expect(source.contains("private func updateFocusedWindowMRU(pid: pid_t)"))
  #expect(source.contains("updateFocusedWindowMRU(pid: pid)"))
  #expect(source.contains("func reconcileFrontmostWithSystem()"))
}

@Test func summonReconcilesFrontmostBeforeSnapshot() throws {
  let source = try switcherSource("SwitcherController.swift")
  let reconcile = try #require(source.range(of: "windowList.reconcileFrontmostWithSystem()"))
  let snapshot = try #require(source.range(of: "windowList.snapshot(applying:"))
  #expect(reconcile.lowerBound < snapshot.lowerBound)
}
