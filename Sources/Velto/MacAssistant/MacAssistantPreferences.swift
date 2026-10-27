import CoreGraphics

/// Mac小助手:零碎小工具的配置。擦屏中与否是运行时状态,故意不持久化 ——
/// 重启后不该还黑屏锁键。
///
/// 字段添加规则同其它模块:只能加,不能改类型/删字段,`init(from:)` 逐个兜底。
struct MacAssistantPreferences: Codable, Equatable {
  /// 擦屏助手的解锁快捷键。必须带 ⌘/⌃/⌥,擦键盘时才不会误触解锁。
  var screenCleanUnlockShortcut = Shortcut(
    keyCode: 37,  // L
    modifierFlags: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).storedRawValue,
    displayName: "⌃⌥⌘L"
  )

  static let defaults = MacAssistantPreferences()

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    screenCleanUnlockShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .screenCleanUnlockShortcut)
      ?? Self.defaults.screenCleanUnlockShortcut
  }
}
