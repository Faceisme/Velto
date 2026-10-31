import Foundation

/// 什么时候算「正在用这个 App」。
enum FocusAutomationTrigger: String, Codable, CaseIterable, Hashable {
  /// 开始播放就算;暂停不结束,窗口全部关闭才结束。
  /// 只开着空窗口不算 —— Movist Pro 单独启动会弹一个空播放窗口。
  case playing
  /// 有窗口就算。
  case window

  var displayName: String {
    switch self {
    case .playing: return "播放视频时"
    case .window: return "有窗口时"
    }
  }
}

struct FocusAutomationApp: Codable, Equatable, Identifiable {
  var bundleID: String
  var trigger: FocusAutomationTrigger = .playing

  var id: String { bundleID }
}

/// 专注自动化:指定 App 在用时跑「打开」快捷指令,全部结束后跑「关闭」快捷指令。
/// macOS 没有开关勿扰的公开 API,只能借快捷指令的「设定专注模式」动作。
///
/// 字段添加规则同其它模块:只能加,不能改类型/删字段,`init(from:)` 逐个兜底。
struct FocusAutomationPreferences: Codable, Equatable {
  var enabled: Bool = false
  var debugLoggingEnabled: Bool = false
  var apps: [FocusAutomationApp] = [FocusAutomationApp(bundleID: "com.movist.MovistPro")]
  var onShortcutName: String = "勿扰开"
  var offShortcutName: String = "勿扰关"
  /// 优先用系统「打开/关闭勿扰模式」快捷键切换(无提示),用不了再走快捷指令。
  var preferSystemHotkey: Bool = true
  /// 列表里的 App 全屏且在最前面时,不让指针碰到程序坞那条屏幕边,程序坞就不会弹出。
  var blockDockInFullScreen: Bool = true

  static let defaults = FocusAutomationPreferences()

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.defaults
    enabled = try c.decodeField(Bool.self, forKey: .enabled, in: decoder) ?? d.enabled
    debugLoggingEnabled = try c.decodeField(Bool.self, forKey: .debugLoggingEnabled, in: decoder) ?? d.debugLoggingEnabled
    apps = try c.decodeField([FocusAutomationApp].self, forKey: .apps, in: decoder) ?? d.apps
    onShortcutName = try c.decodeField(String.self, forKey: .onShortcutName, in: decoder) ?? d.onShortcutName
    offShortcutName = try c.decodeField(String.self, forKey: .offShortcutName, in: decoder) ?? d.offShortcutName
    preferSystemHotkey = try c.decodeField(Bool.self, forKey: .preferSystemHotkey, in: decoder) ?? d.preferSystemHotkey
    blockDockInFullScreen = try c.decodeField(Bool.self, forKey: .blockDockInFullScreen, in: decoder) ?? d.blockDockInFullScreen
  }
}
