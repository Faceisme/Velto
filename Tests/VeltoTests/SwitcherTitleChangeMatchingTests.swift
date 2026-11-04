import ApplicationServices
import Cocoa
import XCTest

@testable import Velto

/// 回归(2026-11-04):标题变化通知到达时,切换器在主线程用 `AXClient.windowID`
/// 认窗口,那是到目标 App 的 RPC。Chrome 新建标签页时它主线程正忙,每次等 40~50ms,
/// 一次新建累计卡住 Velto 主线程 100ms 以上。窗口级通知带的就是订阅时的窗口元素,
/// 改成本地 CFEqual 认窗口。这里用一个不存在的进程造元素:匹配要是走了 RPC 就认不出来。
@MainActor
final class SwitcherTitleChangeMatchingTests: XCTestCase {
  private func unusedPid() -> pid_t {
    var pid: pid_t = 99_000
    while kill(pid, 0) == 0 || errno != ESRCH { pid += 1 }
    return pid
  }

  /// 与 SwitcherApp 暴力枚举同一种 20 字节远程 token:pid、保留位、"coco"、元素 id。
  private func element(pid: pid_t, id: UInt64) throws -> AXUIElement {
    var token = Data(count: 20)
    var pidValue = pid
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: &pidValue) { Data($0) })
    var magic: Int32 = 0x636f_636f
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: &magic) { Data($0) })
    var idValue = id
    token.replaceSubrange(12..<20, with: withUnsafeBytes(of: &idValue) { Data($0) })
    guard let created = _AXUIElementCreateWithRemoteToken(token as CFData) else {
      throw XCTSkip("_AXUIElementCreateWithRemoteToken 不可用")
    }
    return created.takeRetainedValue()
  }

  private func window(_ app: SwitcherApp, wid: CGWindowID, element: AXUIElement) -> SwitcherWindow {
    SwitcherWindow(
      application: app, cgWindowId: wid, axUiElement: element, title: "w\(wid)",
      isMinimized: false, isFullscreen: false, spaceIds: [], position: nil, size: nil)
  }

  func testNotificationElementMatchesTrackedWindowWithoutAskingTheApp() throws {
    let pid = unusedPid()
    let app = SwitcherApp(NSRunningApplication.current)
    let tracked = [
      window(app, wid: 11, element: try element(pid: pid, id: 5)),
      window(app, wid: 12, element: try element(pid: pid, id: 7)),
    ]
    // 通知回调里拿到的是另一个对象,但指向同一个元素。
    let fromNotification = try element(pid: pid, id: 7)
    XCTAssertNil(AXClient.windowID(of: fromNotification), "这个进程不存在,问 wid 必然失败")
    XCTAssertEqual(SwitcherWindowList.trackedWindow(matching: fromNotification, in: tracked)?.cgWindowId, 12)
  }

  func testUnknownElementsDoNotMatch() throws {
    let pid = unusedPid()
    let app = SwitcherApp(NSRunningApplication.current)
    let tracked = [window(app, wid: 11, element: try element(pid: pid, id: 5))]
    XCTAssertNil(SwitcherWindowList.trackedWindow(matching: try element(pid: pid, id: 9), in: tracked))
    XCTAssertNil(SwitcherWindowList.trackedWindow(matching: try element(pid: pid + 1, id: 5), in: tracked))
  }
}
