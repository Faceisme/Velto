import Carbon
import Foundation

/// 一个可被选中的键盘输入源的快照。
struct InputSourceInfo: Identifiable, Equatable {
  /// 持久化 ID = kTISPropertyInputSourceID。
  var id: String
  var localizedName: String
  var sourceLanguages: [String]

  /// 是否中日韩越输入法 —— 决定切换后是否需要 CJKV 二次确认。
  var isCJKV: Bool {
    guard let first = sourceLanguages.first?.lowercased() else { return false }
    return first.hasPrefix("zh") || first == "ja" || first == "ko" || first == "vi"
  }
}

/// TIS 输入源的枚举 / 当前读取 / 查找。所有调用线程安全(纯 Carbon 调用)。
enum InputSourceCatalog {
  /// 全部「可被选中的键盘输入源」,用于 UI Picker 候选与切换查找。
  static func all() -> [InputSourceInfo] {
    guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
    let list = cf as NSArray
    var result: [InputSourceInfo] = []
    for case let raw in list {
      let source = raw as! TISInputSource
      guard isSelectableKeyboardSource(source), let info = info(of: source) else { continue }
      result.append(info)
    }
    return result
  }

  /// 当前正在使用的键盘输入源。
  static func current() -> InputSourceInfo? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return info(of: source)
  }

  /// 按持久化 ID 找到底层 TISInputSource(用于切换)。
  static func tisInputSource(forID id: String) -> TISInputSource? {
    guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
    let list = cf as NSArray
    for case let raw in list {
      let source = raw as! TISInputSource
      guard isSelectableKeyboardSource(source) else { continue }
      if sourceID(of: source) == id { return source }
    }
    return nil
  }

  // MARK: - 私有读取

  private static func isSelectableKeyboardSource(_ source: TISInputSource) -> Bool {
    guard let category = stringProperty(source, kTISPropertyInputSourceCategory),
          category == (kTISCategoryKeyboardInputSource as String)
    else { return false }
    return boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
  }

  private static func info(of source: TISInputSource) -> InputSourceInfo? {
    guard let id = sourceID(of: source) else { return nil }
    let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
    let langs = (arrayProperty(source, kTISPropertyInputSourceLanguages) as? [String]) ?? []
    return InputSourceInfo(id: id, localizedName: name, sourceLanguages: langs)
  }

  private static func sourceID(of source: TISInputSource) -> String? {
    stringProperty(source, kTISPropertyInputSourceID)
  }

  private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
  }

  private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
  }

  private static func arrayProperty(_ source: TISInputSource, _ key: CFString) -> NSArray? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
  }
}
