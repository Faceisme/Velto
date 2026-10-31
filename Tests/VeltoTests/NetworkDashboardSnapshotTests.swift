import Cocoa
import SwiftUI
import XCTest
@testable import Velto

/// 不是断言测试 —— 用真 nettop 数据把网络面板两个页签和下拉菜单头渲染成 PNG 人眼看。
@MainActor
final class NetworkDashboardSnapshotTests: XCTestCase {

  func testRenderDashboardAppsTab() throws {
    guard let outDir = ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_DIR"] else {
      throw XCTSkip("没给 VELTO_SNAPSHOT_DIR,跳过")
    }
    let monitor = NetworkMonitor.shared
    monitor.sampleInterface()
    monitor.sampleProcesses()
    spin(until: { !monitor.apps.isEmpty }, timeout: 6)
    spin(1.1)
    monitor.sampleInterface()
    monitor.sampleProcesses()
    spin(1.5)
    print("SNAPSHOT apps=\(monitor.apps.count) connections=\(monitor.connections.count)")

    let controller = NSHostingController(rootView: NetworkDashboardView())
    controller.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setFrame(NSRect(x: 200, y: 200, width: 1040, height: 640), display: true)
    window.orderBack(nil)
    spin(0.8)
    capture(window, to: "\(outDir)/dash-conn.png")

    // 展开第一个合并行,再刷新两轮数据,看展开状态能不能扛住每秒重建。
    if let outline = find(NSOutlineView.self, in: window.contentView) {
      let row = (0..<outline.numberOfRows).first { outline.isExpandable(outline.item(atRow: $0)) }
      print("SNAPSHOT outline rows=\(outline.numberOfRows) expandable=\(String(describing: row))")
      if let row { outline.expandItem(outline.item(atRow: row)) }
    }
    for _ in 0..<2 {
      spin(1.1)
      monitor.sampleInterface()
      monitor.sampleProcesses()
    }
    spin(0.8)
    capture(window, to: "\(outDir)/dash-conn-expanded.png")

    let segmented = findSegmented(in: window.contentView?.superview)
    print("SNAPSHOT segmented=\(String(describing: segmented))")
    if let segmented {
      segmented.selectedSegment = 1
      segmented.sendAction(segmented.action, to: segmented.target)
    }
    spin(0.8)
    capture(window, to: "\(outDir)/dash-apps.png")
    window.orderOut(nil)

    // 仿菜单底色:液态玻璃上放菜单头,浅色 / 深色各一张。
    for (name, appearance) in [("menu-header", NSAppearance.Name.aqua), ("menu-header-dark", .darkAqua)] {
      let hosting = NSHostingView(rootView: NetworkMenuHeader())
      hosting.frame.size = hosting.fittingSize
      let glass = NSGlassEffectView(frame: hosting.frame.insetBy(dx: -8, dy: -8))
      glass.cornerRadius = 18
      hosting.frame.origin = CGPoint(x: 8, y: 8)
      let container = NSView(frame: glass.frame)
      container.addSubview(hosting)
      glass.contentView = container
      let menu = NSWindow(contentRect: glass.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      menu.appearance = NSAppearance(named: appearance)
      menu.isOpaque = false
      menu.backgroundColor = .clear
      menu.contentView = glass
      menu.orderBack(nil)
      spin(0.6)
      print("SNAPSHOT header=\(hosting.fittingSize)")
      capture(menu, to: "\(outDir)/\(name).png")
      menu.orderOut(nil)
    }
  }

  /// 真菜单:攒 40 秒曲线,等用户停手 2 秒后弹出原生 NSMenu,1 秒后截屏并收起。
  func testRenderRealMenu() throws {
    guard let outDir = ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_DIR"],
          ProcessInfo.processInfo.environment["VELTO_REAL_MENU"] != nil else { throw XCTSkip("跳过") }
    let monitor = NetworkMonitor.shared
    for _ in 0..<40 {
      monitor.sampleInterface()
      monitor.sampleProcesses()
      spin(1.0)
    }
    let idle = { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) }
    spin(until: { idle() >= 2 }, timeout: 60)
    guard idle() >= 2 else { throw XCTSkip("用户一直在操作,不弹菜单") }

    let menu = NSMenu()
    let header = NSMenuItem()
    let hosting = NSHostingView(rootView: NetworkMenuHeader())
    hosting.frame.size = hosting.fittingSize
    header.view = hosting
    menu.addItem(header)
    menu.addItem(.separator())
    menu.addItem(withTitle: "打开网络面板…", action: nil, keyEquivalent: "")
    let screen = NSScreen.screens[0]
    let point = CGPoint(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY - 6)
    let region = "\(Int(point.x) - 24),\(Int(screen.frame.maxY - point.y) - 16),420,\(Int(hosting.frame.height) + 110)"
    nonisolated(unsafe) let tracked = menu
    let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-R", region, "\(outDir)/menu-real.png"]
      try? process.run()
      process.waitUntilExit()
      MainActor.assumeIsolated { tracked.cancelTracking() }
    }
    RunLoop.main.add(timer, forMode: .common)
    menu.popUp(positioning: nil, at: point, in: nil)
    print("SNAPSHOT real menu → \(outDir)/menu-real.png")
  }

  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  }

  private func spin(until done: () -> Bool, timeout: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done(), Date() < deadline { spin(0.05) }
  }

  private func findSegmented(in view: NSView?) -> NSSegmentedControl? {
    guard let view else { return nil }
    if let control = view as? NSSegmentedControl { return control }
    for sub in view.subviews {
      if let found = findSegmented(in: sub) { return found }
    }
    return nil
  }

  private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    if let hit = view as? T { return hit }
    for sub in view.subviews {
      if let found = find(type, in: sub) { return found }
    }
    return nil
  }

  private func capture(_ window: NSWindow, to path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
    try? process.run()
    process.waitUntilExit()
    print("SNAPSHOT → \(path) status=\(process.terminationStatus)")
  }
}
