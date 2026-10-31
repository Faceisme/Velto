import CoreGraphics
import Testing

@testable import Velto

@Suite("事件 tap 宿主")
struct EventTapHostTests {
  private func action(running: Bool, tapsEnabled: Bool, trusted: Bool) -> EventTapHost.HealthAction {
    EventTapHost.healthAction(running: running, tapsEnabled: tapsEnabled, trusted: trusted)
  }

  @Test("授权恢复后启动,没权限时等着,不反复弹授权")
  func startsOnlyWhenTrusted() {
    #expect(action(running: false, tapsEnabled: false, trusted: true) == .start)
    #expect(action(running: false, tapsEnabled: false, trusted: false) == .keep)
  }

  @Test("tap 失效时重建,正常时不动")
  func restartsDeadTap() {
    #expect(action(running: true, tapsEnabled: false, trusted: true) == .restart)
    #expect(action(running: true, tapsEnabled: true, trusted: true) == .keep)
  }

  @Test("权限撤销后停掉,把输入还给系统")
  func stopsWhenTrustRevoked() {
    #expect(action(running: true, tapsEnabled: true, trusted: false) == .stop)
    #expect(action(running: true, tapsEnabled: false, trusted: false) == .stop)
  }

  @Test("没启动时:不报健康,排到 tap 线程的任务直接丢弃")
  func idleHost() {
    let host = EventTapHost(
      name: "test", location: .cghidEventTap, place: .headInsertEventTap, mask: 0
    ) { _, event in Unmanaged.passUnretained(event) }
    var ran = false
    host.perform { ran = true }
    #expect(!ran)
    #expect(!host.ensureEnabled())
    host.stop()
  }
}
