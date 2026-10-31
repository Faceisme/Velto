import Foundation
import Testing

@testable import Velto

/// `shortcuts` 命令没有超时的话,快捷指令卡住就会让 Velto 退不出去。
@Test func cliKillsHungProcessAfterTimeout() {
  let start = Date()
  let result = FocusAutomationController.runCLI("/bin/sleep", ["30"], timeout: 0.2)
  #expect(Date().timeIntervalSince(start) < 5)
  guard case .failure = result else {
    Issue.record("超时应该返回失败: \(result)")
    return
  }
}

@Test func cliReturnsOutputOnSuccess() {
  #expect(FocusAutomationController.runCLI("/bin/echo", ["hi"], timeout: 5) == .success("hi\n"))
}

@Test func cliReportsNonZeroExit() {
  #expect(FocusAutomationController.runCLI("/usr/bin/false", [], timeout: 5) == .failure(""))
}

@Test func cliReportsMissingExecutable() {
  guard case .failure = FocusAutomationController.runCLI("/no/such/tool", [], timeout: 5) else {
    Issue.record("启动失败应该返回失败")
    return
  }
}
