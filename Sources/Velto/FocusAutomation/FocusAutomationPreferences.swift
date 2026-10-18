import Foundation

/// 什么时候算「正在用这个 App」。
enum FocusAutomationTrigger: String, Codable, CaseIterable, Hashable {
  /// 有窗口且开始播放过;直到窗口全部关闭才结束(暂停不结束)。
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

  static let defaults = FocusAutomationPreferences()

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.defaults
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    debugLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? d.debugLoggingEnabled
    apps = try c.decodeIfPresent([FocusAutomationApp].self, forKey: .apps) ?? d.apps
    onShortcutName = try c.decodeIfPresent(String.self, forKey: .onShortcutName) ?? d.onShortcutName
    offShortcutName = try c.decodeIfPresent(String.self, forKey: .offShortcutName) ?? d.offShortcutName
  }
}
