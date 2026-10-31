import Cocoa
import SwiftUI
import XCTest
@testable import Velto

/// 不是断言测试 —— 按真实设置窗口的样子把每个设置页(含分页)离屏渲染成 PNG 人眼看。
/// 数据从真实偏好域 com.face.myapp 只读取来,塞进进程内的参数域(volatile,不落盘)。
@MainActor
final class SettingsPagesSnapshotTests: XCTestCase {

  func testRenderAllPages() throws {
    guard let outDir = ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_DIR"] else {
      throw XCTSkip("没给 VELTO_SNAPSHOT_DIR,跳过")
    }
    seedFromRealDomain()
    seedMouseDemo()
    print("SNAPSHOT gestures=\(GestureStore.shared.gestures.count)")

    let only = ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_PAGES"]?
      .split(separator: ",").map(String.init)
    // 页面顶部分段控件的第几段
    let segments: [MGPage: [(String, Int)]] = [
      .gestures: [("设置", 1)],
      .inputSourceSwitch: [("应用规则", 1), ("浏览器规则", 2)],
    ]
    for page in MGPage.allCases where only?.contains(page.rawValue) ?? true {
      for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let window = makeWindow(page: page, appearance: appearance)
        spin(1.0)
        shoot(window, "\(outDir)/\(page.rawValue)-\(suffix)")
        for (title, index) in segments[page] ?? [] {
          window.setFrame(frame, display: true)
          spin(0.3)
          selectSegment(index, in: window)
          spin(0.8)
          shoot(window, "\(outDir)/\(page.rawValue)-\(title)-\(suffix)")
        }
        window.orderOut(nil)
        window.close()
      }
    }
  }

  // MARK: - 窗口

  /// VELTO_SNAPSHOT_SIZE=960x640 看最小窗口;默认 1180×760(设置窗口初始尺寸)。
  private var size: CGSize {
    let parts = ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_SIZE"]?
      .split(separator: "x").compactMap { Double($0) } ?? []
    return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1180, height: 760)
  }

  private var frame: NSRect { NSRect(origin: CGPoint(x: 80, y: 80), size: size) }

  private func makeWindow(page: MGPage, appearance: NSAppearance.Name) -> NSWindow {
    let root = HStack(spacing: 0) {
      SidebarView(page: .constant(page)).frame(width: 220)
      pageView(page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mgBg)
    }
    let controller = NSHostingController(rootView: root)
    controller.sizingOptions = []
    let window = SnapshotWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isOpaque = false
    window.backgroundColor = .clear
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.setFrame(frame, display: true)
    window.orderBack(nil)
    return window
  }

  private func pageView(_ page: MGPage) -> AnyView {
    switch page {
    case .gestures: AnyView(GesturesPage())
    case .mouseControl: AnyView(MouseControlPage())
    case .window: AnyView(WindowManagementPage())
    case .switcher: AnyView(SwitcherSettingsPage())
    case .inputSourceSwitch: AnyView(InputSourceSwitchPage())
    case .keyRemap: AnyView(KeyRemapPage())
    case .betterFinder: AnyView(BetterFinderPage())
    case .screenshot: AnyView(ScreenshotPage())
    case .networkMonitor: AnyView(NetworkMonitorPage())
    case .focusAutomation: AnyView(FocusAutomationPage())
    case .macAssistant: AnyView(MacAssistantPage())
    case .general: AnyView(GeneralSettingsPage())
    }
  }

  /// 首屏一张;页面内容更长时把窗口拉到内容全高再来一张 -full。
  private func shoot(_ window: NSWindow, _ base: String) {
    window.setFrame(frame, display: true)
    spin(0.4)
    capture(window, to: "\(base).png")
    let docHeight = views(NSScrollView.self, in: window.contentView)
      .compactMap { $0.documentView?.frame.height }
      .max() ?? 0
    guard docHeight > size.height - 60 else { return }
    window.setFrame(NSRect(x: 80, y: 80, width: size.width, height: docHeight + 80), display: true)
    spin(0.6)
    capture(window, to: "\(base)-full.png")
  }

  // MARK: - 数据

  private func seedFromRealDomain() {
    guard let real = UserDefaults(suiteName: "com.face.myapp") else { return }
    let keys = [
      "Velto.gestures", "Velto.preferences",
      "Velto.keyRemaps", "Velto.keyRemapEnabled", "Velto.keyRemapDebugLogging",
    ]
    let defaults = UserDefaults.standard
    var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    for key in keys {
      if let value = real.object(forKey: key) { args[key] = value }
    }
    defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
  }

  /// VELTO_SNAPSHOT_DEMO=1:给鼠标控制塞几条按钮绑定和按应用覆盖,看有数据时的排版。只改进程内参数域。
  private func seedMouseDemo() {
    guard ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_DEMO"] == "1" else { return }
    let defaults = UserDefaults.standard
    var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var prefs = (args["Velto.preferences"] as? Data)
      .flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? .defaults
    func side(_ code: UInt16, _ name: String) -> MouseInputTrigger {
      MouseInputTrigger(kind: .mouse, code: code, displayName: name)
    }
    let missionControl = MouseButtonBinding(name: "调度中心", trigger: side(3, "侧键1"), action: .system(.missionControl))
    prefs.mouseControl.buttonBindings = [
      missionControl,
      MouseButtonBinding(
        name: "关闭标签", trigger: side(4, "侧键2"),
        action: .shortcut(Shortcut(keyCode: VirtualKeyCode.w, modifierFlags: CGEventFlags.maskCommand.storedRawValue, displayName: "⌘W"))
      ),
      MouseButtonBinding(
        name: "打开 Safari", isEnabled: false, trigger: side(2, "中键"),
        action: .openApplication(path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari")
      ),
      MouseButtonBinding(name: "跑脚本", trigger: side(5, "侧键3"), action: .runScript("open -a Finder")),
    ]
    var safari = MouseAppRule(
      bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app",
      inheritScroll: false, inheritButtons: false,
      scroll: prefs.mouseControl.scroll, hotkeys: prefs.mouseControl.hotkeys, buttonBindings: [missionControl]
    )
    safari.scroll.smooth = false
    prefs.mouseControl.appRules = [
      safari,
      MouseAppRule(bundleIdentifier: "com.apple.finder", displayName: "访达", path: "/System/Library/CoreServices/Finder.app"),
    ]
    prefs.inputSourceSwitch.browserRules = [
      InputSourceBrowserRule(
        type: .domainSuffix, value: "github.com", sample: "https://github.com/anthropics",
        inputSourceID: prefs.inputSourceSwitch.systemDefaultInputSourceID
      ),
      InputSourceBrowserRule(type: .urlRegex, value: "^https://docs\\.google\\.com/", isEnabled: false),
    ]
    prefs.inputSourceSwitch.cjkFixEnabled = true
    args["Velto.preferences"] = try? JSONEncoder().encode(prefs)
    defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
  }

  // MARK: - 辅助

  /// 切最靠上的原生分段控件。不合成点击:NSSegmentedControl 按下会进跟踪循环等队列里的 mouseUp。
  private func selectSegment(_ index: Int, in window: NSWindow) {
    guard let control = views(NSSegmentedControl.self, in: window.contentView)
      .max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY })
    else { return XCTFail("没找到分段控件") }
    control.selectedSegment = index
    control.sendAction(control.action, to: control.target)
  }

  private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { views(type, in: $0) }
  }

  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
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

/// 允许窗口高于屏幕(长页一次截全);假装是 key 窗口,控件按激活态绘制。
private final class SnapshotWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
  override var isKeyWindow: Bool { true }
}
