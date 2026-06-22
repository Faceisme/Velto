import AppKit
import Foundation
import VeltoAnnotationCore

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
  /// 会话内:滚动长截图(默认 S 1)
  var scrollKeyCode: UInt16
  /// ⌘S 静默保存目录,默认桌面
  var saveDirectoryPath: String
  /// 保存时是否同时复制到剪贴板,默认关
  var saveAlsoCopiesToClipboard: Bool
  var imageFormat: ScreenshotImageFormat
  /// 取色放大镜,默认开
  var showMagnifier: Bool
  /// 调试日志:开启后把截图会话、窗口识别等细节写入 `~/Library/Logs/Velto/screenshot-debug.log`,
  /// 供排查问题用,默认关。
  var debugLoggingEnabled: Bool

  // MARK: - 标注默认样式(新建画布与重置工具时的初值)

  /// 描边/文字默认颜色,默认系统红。
  var annotationColor: AnnotationColor
  /// 形状/箭头默认线宽,默认 3。
  var annotationLineWidth: CGFloat
  /// 文字默认字号,默认 18。
  var annotationFontSize: CGFloat
  /// 高亮笔默认透明度,默认 0.35。
  var annotationHighlightOpacity: CGFloat
  /// 马赛克默认粒度,默认 12。
  var annotationMosaicBlockSize: Int
  /// 形状默认填充透明度,默认 0(空心)。
  var annotationFillOpacity: CGFloat

  /// 把六个默认设置映射为编辑器初始 AnnotationStyle;其余字段沿用编辑器约定。
  var annotationStyle: AnnotationStyle {
    AnnotationStyle(
      strokeColor: annotationColor,
      lineWidth: annotationLineWidth,
      fillColor: annotationColor,
      fillOpacity: annotationFillOpacity,
      fontSize: annotationFontSize,
      isBold: false,
      textAlignment: .left,
      highlightOpacity: annotationHighlightOpacity,
      mosaicBlockSize: annotationMosaicBlockSize,
      sequenceDiameter: 28
    )
  }

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
    showMagnifier: true,
    debugLoggingEnabled: false,
    annotationColor: .systemRed,
    annotationLineWidth: 3,
    annotationFontSize: 18,
    annotationHighlightOpacity: 0.35,
    annotationMosaicBlockSize: 12,
    annotationFillOpacity: 0
  )

  init(
    enabled: Bool, triggerShortcut: Shortcut?, copyKeyCode: UInt16, saveShortcut: Shortcut,
    cancelKeyCode: UInt16, scrollKeyCode: UInt16, saveDirectoryPath: String,
    saveAlsoCopiesToClipboard: Bool, imageFormat: ScreenshotImageFormat, showMagnifier: Bool,
    debugLoggingEnabled: Bool,
    annotationColor: AnnotationColor, annotationLineWidth: CGFloat, annotationFontSize: CGFloat,
    annotationHighlightOpacity: CGFloat, annotationMosaicBlockSize: Int, annotationFillOpacity: CGFloat
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
    self.debugLoggingEnabled = debugLoggingEnabled
    self.annotationColor = annotationColor
    self.annotationLineWidth = annotationLineWidth
    self.annotationFontSize = annotationFontSize
    self.annotationHighlightOpacity = annotationHighlightOpacity
    self.annotationMosaicBlockSize = annotationMosaicBlockSize
    self.annotationFillOpacity = annotationFillOpacity
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
    debugLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? d.debugLoggingEnabled
    annotationColor = try c.decodeIfPresent(AnnotationColor.self, forKey: .annotationColor) ?? d.annotationColor
    annotationLineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .annotationLineWidth) ?? d.annotationLineWidth
    annotationFontSize = try c.decodeIfPresent(CGFloat.self, forKey: .annotationFontSize) ?? d.annotationFontSize
    annotationHighlightOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .annotationHighlightOpacity) ?? d.annotationHighlightOpacity
    annotationMosaicBlockSize = try c.decodeIfPresent(Int.self, forKey: .annotationMosaicBlockSize) ?? d.annotationMosaicBlockSize
    annotationFillOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .annotationFillOpacity) ?? d.annotationFillOpacity
  }
}
