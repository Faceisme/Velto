import XCTest
import Cocoa
@testable import Velto

/// 切换器 P0/P1/P2 重构的回归测试(2026-08-26)。
///
/// 覆盖:
///   - tile 逐窗口复用(窗口增删不再整盘重建)
///   - 缩放布局的 frame/bounds 设置顺序(反了缩放会静默失效)
///   - 选中高亮独立 layer:首次落位不动画、step 才弹
///   - 缩略图时效戳
///   - hover 不许抢键盘选中(源码结构断言,controller 起不来)
@MainActor
final class SwitcherTileReuseHighlightTests: XCTestCase {

  // MARK: - 夹具

  /// 用当前测试进程伪造一个 SwitcherApp —— 只用到 icon / localizedName,
  /// AXUIElement 全程不会被真正 query。
  private func makeApp() -> SwitcherApp {
    SwitcherApp(NSRunningApplication.current)
  }

  private func makeWindow(_ app: SwitcherApp, wid: CGWindowID, title: String) -> SwitcherWindow {
    SwitcherWindow(
      application: app,
      cgWindowId: wid,
      axUiElement: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      title: title,
      isMinimized: false,
      isFullscreen: false,
      spaceIds: [],
      position: nil,
      size: nil
    )
  }

  private let roomySize = NSSize(width: 2000, height: 2000)

  // MARK: - tile 复用

  func testRemovingOneWindowKeepsOtherTiles() {
    let app = makeApp()
    let w = (0..<3).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    XCTAssertEqual(view.tiles.count, 3)
    let t0 = view.tiles[0], t2 = view.tiles[2], t1 = view.tiles[1]

    // 关掉中间那个 —— 剩下两个 tile 必须是原来那两个对象(没整盘重建)
    view.rebuild(with: [w[0], w[2]], maxSize: roomySize)
    XCTAssertEqual(view.tiles.count, 2)
    XCTAssertTrue(view.tiles[0] === t0)
    XCTAssertTrue(view.tiles[1] === t2)
    // 被淘汰的 tile 必须真的下线,不能留在视图树里吃事件
    XCTAssertNil(t1.superview)
    XCTAssertEqual(view.subviews.count, 2)
  }

  func testAddingWindowOnlyCreatesTheNewTile() {
    let app = makeApp()
    let w = (0..<2).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let fresh = makeWindow(app, wid: 99, title: "new")
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    let t0 = view.tiles[0], t1 = view.tiles[1]

    // 新窗口插到最前(MRU 提升)—— 老的两个原地复用,只多造一个
    view.rebuild(with: [fresh, w[0], w[1]], maxSize: roomySize)
    XCTAssertEqual(view.tiles.count, 3)
    XCTAssertFalse(view.tiles[0] === t0)
    XCTAssertTrue(view.tiles[1] === t0)
    XCTAssertTrue(view.tiles[2] === t1)
    XCTAssertTrue(view.tiles[0].window_ === fresh)
  }

  func testScaleChangeForcesFullRebuild() {
    let app = makeApp()
    let w = (0..<12).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    let old = view.tiles
    // 缩放靠改 tile 的 bounds 实现 —— 缩放比变了只能全量重建
    view.rebuild(with: w, maxSize: NSSize(width: 800, height: 300))
    XCTAssertEqual(view.tiles.count, 12)
    for (a, b) in zip(old, view.tiles) {
      XCTAssertFalse(a === b)
    }
    XCTAssertEqual(view.subviews.count, 12, "旧 tile 必须全下线,不能残留在视图树里")
  }

  func testColumnCountChangeStillReusesTiles() {
    let app = makeApp()
    let w = (0..<6).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    let old = view.tiles
    // 窄一点 → 列数变但 scale 仍是 1 → tile 本身没变,只是换位置,必须复用
    view.rebuild(with: w, maxSize: NSSize(width: 600, height: 2000))
    for (a, b) in zip(old, view.tiles) {
      XCTAssertTrue(a === b)
    }
    // 位置得真的按新列数重排(6 个 2 列 → 3 行)
    XCTAssertEqual(view.tiles[0].frame.minX, view.tiles[2].frame.minX, accuracy: 0.01)
    XCTAssertGreaterThan(view.tiles[0].frame.minY, view.tiles[2].frame.minY)
  }

  func testMaxSizeJitterDoesNotBreakReuse() {
    let app = makeApp()
    let w = (0..<3).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    let old = view.tiles
    // Dock 自动隐藏 / 菜单栏导致 visibleFrame 抖几个点 —— 布局结果没变,不许重建
    view.rebuild(with: w, maxSize: NSSize(width: 1990, height: 1987))
    for (a, b) in zip(old, view.tiles) {
      XCTAssertTrue(a === b)
    }
  }

  // MARK: - 缩放:frame 必须先于 bounds

  func testScaledTileKeepsFullSizeBounds() {
    let app = makeApp()
    let w = (0..<12).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))
    let tight = NSSize(width: 800, height: 300)

    let layout = SwitcherTilesLayout(
      count: 12, style: .thumbnails, maxSize: tight, spacing: 8, inset: 24
    )
    XCTAssertLessThan(layout.scale, 1, "夹具没造出缩放场景,测试无意义")

    view.rebuild(with: w, maxSize: tight)
    let full = SwitcherTileView.tileSize(for: .thumbnails)
    for t in view.tiles {
      // bounds 保持满尺寸 = 内容整体等比缩小;反了的话 setFrame 会把 bounds 拉平,
      // 缩放静默失效(缩略图 / 文字全按满尺寸画,溢出格子)
      XCTAssertEqual(t.bounds.width, full.width, accuracy: 0.01)
      XCTAssertEqual(t.bounds.height, full.height, accuracy: 0.01)
      XCTAssertEqual(t.frame.width, full.width * layout.scale, accuracy: 0.01)
    }
  }

  // MARK: - 选中高亮

  func testFirstSelectionSnapsWithoutAnimation() {
    let app = makeApp()
    let w = (0..<3).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    XCTAssertTrue(view.selectionLayer.isHidden, "rebuild 后高亮必须先收起")

    view.setSelectedIndex(0)
    XCTAssertFalse(view.selectionLayer.isHidden)
    // 面板刚弹出来,高亮就该在第 0 格上 —— 不许从上一轮的位置飞过来
    XCTAssertNil(view.selectionLayer.animation(forKey: "selection"))
    XCTAssertEqual(view.selectionLayer.position.x, view.tiles[0].frame.midX, accuracy: 0.01)
    XCTAssertEqual(view.selectionLayer.position.y, view.tiles[0].frame.midY, accuracy: 0.01)
  }

  func testSteppingAnimatesAndLandsOnTarget() throws {
    let app = makeApp()
    let w = (0..<3).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    view.setSelectedIndex(0)
    view.setSelectedIndex(1)

    let anim = view.selectionLayer.animation(forKey: "selection")
    XCTAssertNotNil(anim, "session 内换格子必须有位移动画,否则就是老的瞬移")
    let spring = try XCTUnwrap(anim as? CASpringAnimation)
    // 速度红线:连按 Tab 时高亮不许拖在手后面。ζ 保持 ~0.92(不过冲),
    // 收敛时间由 stiffness 决定 —— 这两条一起钉住,以后谁调软了立刻红。
    XCTAssertLessThan(spring.settlingDuration, 0.2, "高亮收敛超过 0.2s = 又变回拖沓")
    let zeta = spring.damping / (2 * sqrt(spring.stiffness * spring.mass))
    XCTAssertEqual(zeta, 0.92, accuracy: 0.06, "阻尼比跑偏:太小会过冲,太大退化成瞬移")
    // 动画只管过程,模型值必须**立刻**落在目标格 —— 否则中途再 step 会从错的地方起跳
    XCTAssertEqual(view.selectionLayer.position.x, view.tiles[1].frame.midX, accuracy: 0.01)
    XCTAssertEqual(view.selectionLayer.position.y, view.tiles[1].frame.midY, accuracy: 0.01)
  }

  func testRepeatedSelectionOfSameIndexDoesNotReanimate() {
    let app = makeApp()
    let w = (0..<3).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    view.setSelectedIndex(0)
    // hover 会高频重复投同一个 index —— 不能每次都重起一次弹簧
    view.setSelectedIndex(0)
    XCTAssertNil(view.selectionLayer.animation(forKey: "selection"))
  }

  func testSelectionLayerStaysBehindTiles() {
    let app = makeApp()
    let w = (0..<3).map { makeWindow(app, wid: CGWindowID($0), title: "win\($0)") }
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    // 高亮是"垫在下面"的底色,浮到 tile 上面会把缩略图糊住
    XCTAssertTrue(view.layer?.sublayers?.first === view.selectionLayer)
  }

  func testOutOfRangeSelectionHidesHighlight() {
    let app = makeApp()
    let w = [makeWindow(app, wid: 1, title: "only")]
    let view = SwitcherTilesView(frame: NSRect(origin: .zero, size: roomySize))

    view.rebuild(with: w, maxSize: roomySize)
    view.setSelectedIndex(0)
    view.setSelectedIndex(-1)
    XCTAssertTrue(view.selectionLayer.isHidden)
  }

  // MARK: - 缩略图时效

  func testThumbnailTimestampTracksWrites() {
    let app = makeApp()
    let win = makeWindow(app, wid: 1, title: "w")
    XCTAssertNil(win.thumbnail)
    XCTAssertEqual(win.thumbnailCapturedAt, 0)

    let before = CFAbsoluteTimeGetCurrent()
    win.setThumbnail(.cgImage(nil))
    XCTAssertNotNil(win.thumbnail)
    XCTAssertGreaterThanOrEqual(win.thumbnailCapturedAt, before)

    win.setThumbnail(nil)
    XCTAssertNil(win.thumbnail)
    XCTAssertEqual(win.thumbnailCapturedAt, 0, "释放图必须同时清时效戳,否则会被当成新鲜图跳过重抓")
  }

  // MARK: - 源码结构断言(controller 在测试进程里起不来)

  private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // VeltoTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // 仓库根
    return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
  }

  func testHoverCannotStealKeyboardSelection() throws {
    let src = try source("Sources/Velto/Switcher/SwitcherController.swift")
    XCTAssertTrue(src.contains("private var hoverArmPoint: NSPoint?"))
    // 键盘 step 必须重新武装守卫
    XCTAssertTrue(src.contains("hoverArmPoint = NSEvent.mouseLocation"))
    // hover 进来先过守卫再改选中
    XCTAssertTrue(
      src.contains("if index >= 0, !mouseMovedEnoughToTakeOver() { return }"),
      "handleHover 必须先过 hover 守卫 —— 否则光标压在哪格就选哪格,键盘选的会被抖掉"
    )
  }

  func testKeyTapArmedBeforeSnapshot() throws {
    let src = try source("Sources/Velto/Switcher/SwitcherController.swift")
    let arm = try XCTUnwrap(src.range(of: "keyTap.isActive = true"))
    let snap = try XCTUnwrap(src.range(of: "let snapshot = windowList.snapshot("))
    XCTAssertTrue(
      arm.lowerBound < snap.lowerBound,
      "取快照是同步 IPC,期间 isActive 还是 false 的话方向键 / Esc 会漏进前台 app"
    )
  }

  func testKeyEventsHopToMainInFifoOrder() throws {
    let src = try source("Sources/Velto/Switcher/SwitcherController.swift")
    XCTAssertTrue(
      src.contains("DispatchQueue.main.async {\n                self?.handleKeyEvent(event)"),
      "键盘事件必须走主队列(严格 FIFO);Task 的 hop 不保证顺序,连敲 Tab 会丢格"
    )
  }

  func testPanelFallsBackToNearestScreen() throws {
    let src = try source("Sources/Velto/Switcher/SwitcherPanel.swift")
    XCTAssertTrue(src.contains("squaredDistance"))
    XCTAssertTrue(
      src.contains("return NSScreen.screens.min {"),
      "光标压在屏幕边界时 frame.contains 会全失手,必须退化到最近的屏而不是 NSScreen.main"
    )
  }
}
