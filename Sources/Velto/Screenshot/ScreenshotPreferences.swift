import AppKit
import Foundation

enum ScreenshotImageFormat: String, Codable, Equatable, CaseIterable {
  case png
}

/// 截图模块全部配置。嵌进 AppPreferences,与手势/切换器共享一份 JSON 持久化。
/// keyCode 默认值:空格 49、S 1、Esc 53;saveShortcut 默认 ⌘S(keyCode 1 + maskCommand)。
struct ScreenshotPreferences: Codable, Equatable {
  var enabled: Bool
  /// 全局触发键。默认 nil:首次让用户在设置里录,避免与系统 ⌘⇧3/4/5 冲突。
  var triggerShortcut: Shortcut?
  /// 会话内:复制到剪贴板(默认空格 49)
  var copyKeyCode: UInt16
  /// 会话内:存预设目录(默认 ⌘S)
  var saveShortcut: Shortcut
  /// 会话内:取消(默认 Esc 53)
  var cancelKeyCode: UInt16
  /// 会话内:滚动长截图(默认 S 1)—— Phase 3 占位,本期不实现拼接
  var scrollKeyCode: UInt16
  /// ⌘S 静默保存目录,默认桌面
  var saveDirectoryPath: String
  /// 保存时是否同时复制到剪贴板,默认关
  var saveAlsoCopiesToClipboard: Bool
  var imageFormat: ScreenshotImageFormat
  /// 取色放大镜,默认开
  var showMagnifier: Bool

  static let defaults = ScreenshotPreferences(
    enabled: true,
    triggerShortcut: nil,
    copyKeyCode: 49,
    saveShortcut: Shortcut(
      keyCode: 1,
      modifierFlags: UInt64(CGEventFlags.maskCommand.rawValue),
      displayName: "⌘S"
    ),
    cancelKeyCode: 53,
    scrollKeyCode: 1,
    saveDirectoryPath: (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
      ?? NSHomeDirectory() + "/Desktop"),
    saveAlsoCopiesToClipboard: false,
    imageFormat: .png,
    showMagnifier: true
  )

  init(
    enabled: Bool, triggerShortcut: Shortcut?, copyKeyCode: UInt16, saveShortcut: Shortcut,
    cancelKeyCode: UInt16, scrollKeyCode: UInt16, saveDirectoryPath: String,
    saveAlsoCopiesToClipboard: Bool, imageFormat: ScreenshotImageFormat, showMagnifier: Bool
  ) {
    self.enabled = enabled
    self.triggerShortcut = triggerShortcut
    self.copyKeyCode = copyKeyCode
    self.saveShortcut = saveShortcut
    self.cancelKeyCode = cancelKeyCode
    self.scrollKeyCode = scrollKeyCode
    self.saveDirectoryPath = saveDirectoryPath
    self.saveAlsoCopiesToClipboard = saveAlsoCopiesToClipboard
    self.imageFormat = imageFormat
    self.showMagnifier = showMagnifier
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.defaults
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    triggerShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .triggerShortcut) ?? d.triggerShortcut
    copyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .copyKeyCode) ?? d.copyKeyCode
    saveShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .saveShortcut) ?? d.saveShortcut
    cancelKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .cancelKeyCode) ?? d.cancelKeyCode
    scrollKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .scrollKeyCode) ?? d.scrollKeyCode
    saveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .saveDirectoryPath) ?? d.saveDirectoryPath
    saveAlsoCopiesToClipboard = try c.decodeIfPresent(Bool.self, forKey: .saveAlsoCopiesToClipboard) ?? d.saveAlsoCopiesToClipboard
    imageFormat = try c.decodeIfPresent(ScreenshotImageFormat.self, forKey: .imageFormat) ?? d.imageFormat
    showMagnifier = try c.decodeIfPresent(Bool.self, forKey: .showMagnifier) ?? d.showMagnifier
  }
}
