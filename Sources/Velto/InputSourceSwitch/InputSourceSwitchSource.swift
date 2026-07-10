import Carbon
import Foundation

/// 一个可被选中的键盘输入源的快照。
struct InputSourceInfo: Identifiable, Equatable {
  /// kTISPropertyInputSourceID。
  var sourceID: String
  /// kTISPropertyInputModeID。同一个 source 下不同模式必须靠它区分。
  var inputModeID: String?
  var localizedName: String
  var sourceLanguages: [String]
  var isEnabled: Bool
  /// kTISPropertyBundleID:输入法宿主进程的 bundle id(键盘布局无宿主为 nil)。
  /// 强制英文标点靠它定位 IME 进程,查候选窗是否在屏。
  var bundleID: String?

  /// 持久化 ID。对齐 InputSourcePro:sourceID::inputModeID。
  var id: String {
    if let inputModeID, !inputModeID.isEmpty {
      return "\(sourceID)::\(inputModeID)"
    }
    return sourceID
  }

  /// 是否中日韩越输入法 —— 决定切换后是否需要 CJKV 二次确认。
  var isCJKV: Bool {
    guard let first = sourceLanguages.first?.lowercased() else { return false }
    return first.hasPrefix("zh") || first == "ja" || first == "ko" || first == "vi" || first == "ru"
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
  static func tisInputSource(forID persistentID: String) -> TISInputSource? {
    let target = splitPersistentID(persistentID)
    guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
    let list = cf as NSArray
    var selectableSources: [TISInputSource] = []
    var sourceIDMatches: [TISInputSource] = []
    for case let raw in list {
      let source = raw as! TISInputSource
      guard isSelectableKeyboardSource(source) else { continue }
      selectableSources.append(source)
      guard sourceID(of: source) == target.sourceID else { continue }
      if let inputModeID = target.inputModeID {
        if inputModeIDOf(source) == inputModeID { return source }
      } else {
        sourceIDMatches.append(source)
      }
    }
    if let base = sourceIDMatches.first(where: { inputModeIDOf($0) == nil }) {
      return base
    }
    if let legacyModeMatch = selectableSources.first(where: {
      isSelectableKeyboardSource($0) && inputModeIDOf($0) == persistentID
    }) {
      return legacyModeMatch
    }
    return sourceIDMatches.first
  }

  // MARK: - 私有读取

  private static func isSelectableKeyboardSource(_ source: TISInputSource) -> Bool {
    guard let category = stringProperty(source, kTISPropertyInputSourceCategory),
          category == (kTISCategoryKeyboardInputSource as String)
    else { return false }
    return boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
  }

  private static func info(of source: TISInputSource) -> InputSourceInfo? {
    guard let sourceID = sourceID(of: source) else { return nil }
    let name = stringProperty(source, kTISPropertyLocalizedName) ?? sourceID
    let inputModeID = inputModeIDOf(source)
    let langs = (arrayProperty(source, kTISPropertyInputSourceLanguages) as? [String]) ?? []
    let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled)
    return InputSourceInfo(
      sourceID: sourceID,
      inputModeID: inputModeID,
      localizedName: name,
      sourceLanguages: langs,
      isEnabled: enabled,
      bundleID: stringProperty(source, kTISPropertyBundleID)
    )
  }

  private static func sourceID(of source: TISInputSource) -> String? {
    stringProperty(source, kTISPropertyInputSourceID)
  }

  private static func inputModeIDOf(_ source: TISInputSource) -> String? {
    guard let value = stringProperty(source, kTISPropertyInputModeID), !value.isEmpty else { return nil }
    return value
  }

  private static func splitPersistentID(_ id: String) -> (sourceID: String, inputModeID: String?) {
    let parts = id.components(separatedBy: "::")
    guard parts.count >= 2 else { return (id, nil) }
    let sourceID = parts[0]
    let inputModeID = parts.dropFirst().joined(separator: "::")
    return (sourceID, inputModeID.isEmpty ? nil : inputModeID)
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
