import AppKit
import Testing

@testable import Velto

@Suite("窗口快照")
struct WindowSnapshotTests {
  private let rect = CGRect(x: 10, y: 20, width: 300, height: 200)

  private func row(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var row: [String: Any] = [
      kCGWindowNumber as String: 42,
      kCGWindowOwnerPID as String: Int32(1234),
      kCGWindowOwnerName as String: "Finder",
      kCGWindowName as String: "下载",
      kCGWindowLayer as String: 3,
      kCGWindowAlpha as String: 0.5,
      kCGWindowIsOnscreen as String: true,
      kCGWindowBounds as String: rect.dictionaryRepresentation,
    ]
    edit(&row)
    return row
  }

  @Test("解析一行 CGWindowList")
  func parsesRow() {
    let window = WindowInfo(row: row())
    #expect(window?.id == 42)
    #expect(window?.pid == 1234)
    #expect(window?.ownerName == "Finder")
    #expect(window?.name == "下载")
    #expect(window?.layer == 3)
    #expect(window?.alpha == 0.5)
    #expect(window?.isOnscreen == true)
    #expect(window?.bounds == rect)
  }

  @Test("可选字段缺失时用默认值")
  func optionalKeysHaveDefaults() {
    let window = WindowInfo(row: row {
      $0[kCGWindowOwnerName as String] = nil
      $0[kCGWindowName as String] = nil
      $0[kCGWindowIsOnscreen as String] = nil
    })
    #expect(window?.ownerName == "")
    #expect(window?.name == nil)
    #expect(window?.isOnscreen == false)
  }

  @Test("必需字段缺失时跳过这一行")
  func requiredKeysAreChecked() {
    for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds] {
      #expect(WindowInfo(row: row { $0[key as String] = nil }) == nil)
    }
  }

  @Test("真实枚举能解析出 Velto 测试进程之外的窗口结构")
  func liveSnapshotParses() {
    // CI 无窗口时为空也算过,这里只验证解析不丢字段。
    for window in WindowSnapshot.onScreen().windows {
      #expect(window.id != 0)
      #expect(window.pid > 0)
    }
  }

  @Test("光标下最上层的普通窗口:跳过自己、浮动层、不可见和太小的")
  func topmostAppWindow() {
    let point = CGPoint(x: 100, y: 100)
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    let target = WindowInfo(id: 1, pid: getpid() + 1, bounds: frame)
    let snapshot = WindowSnapshot([
      WindowInfo(id: 2, pid: getpid(), bounds: frame),
      WindowInfo(id: 3, pid: getpid() + 2, layer: 3, bounds: frame),
      WindowInfo(id: 4, pid: getpid() + 2, bounds: frame, alpha: 0),
      WindowInfo(id: 5, pid: getpid() + 2, bounds: frame, isOnscreen: false),
      WindowInfo(id: 6, pid: getpid() + 2, bounds: CGRect(x: 90, y: 90, width: 30, height: 30)),
      target,
    ])
    #expect(snapshot.topmostAppWindow(at: point) == target)
    #expect(snapshot.topmostOwnWindow(at: point)?.id == 2)
    #expect(snapshot.topmostAppWindow(at: CGPoint(x: 300, y: 300)) == nil)
  }

  @Test("App 窗口查询包含浮动层,按从前到后排列")
  func appWindowsKeepOrder() {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    let floating = WindowInfo(id: 1, pid: 7, layer: 3, bounds: frame)
    let normal = WindowInfo(id: 2, pid: 7, bounds: frame)
    let snapshot = WindowSnapshot([
      WindowInfo(id: 3, pid: 7, layer: 25, bounds: frame),
      floating,
      WindowInfo(id: 4, pid: 8, bounds: frame),
      normal,
    ])
    #expect(snapshot.appWindows(of: 7) == [floating, normal])
    #expect(snapshot.containsWindow(of: 8))
    #expect(!snapshot.containsWindow(of: 9))
  }

  @Test("窗口的 App 名取第一个非空的")
  func ownerName() {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    let snapshot = WindowSnapshot([
      WindowInfo(pid: 7, ownerName: "", bounds: frame),
      WindowInfo(pid: 7, ownerName: "Movist", bounds: frame),
    ])
    #expect(snapshot.ownerName(of: 7) == "Movist")
    #expect(snapshot.ownerName(of: 8) == nil)
  }
}
