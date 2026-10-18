import CoreGraphics
import Foundation

/// 开关勿扰。优先模拟系统「打开/关闭勿扰模式」快捷键(默认 fn+F5),没有任何提示;
/// 用不了或按了没生效再退回快捷指令(每次运行菜单栏都会闪一个运行指示,隐藏不掉)。
///
/// 系统快捷键只能切换,所以按之前要知道勿扰现在开没开:读专注状态文件
/// ~/Library/DoNotDisturb/DB/Assertions.json,这需要「完全磁盘访问权限」。
/// 手动打开的专注会在里面留一条记录,关掉就删掉;按日程自动开的专注不在里面。
///
/// 只在 FocusAutomationController 的串行队列上用,状态不需要再加锁。
final class DoNotDisturbSwitch: @unchecked Sendable {
  enum Outcome {
    /// 由我们打开 / 关闭了,`via` 是用的方式。
    case done(via: String)
    /// 本来就开着(用户手动开的或别的专注),不归我们管。
    case alreadyOn
    /// 本来就关了,或者不是我们开的,不用动。
    case skipped
    case failed(String)
  }

  /// 勿扰是不是我们打开的;只关自己开的。
  private var ownedByUs = false

  private static let assertionsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
  /// 按下快捷键后等专注状态文件变化的最长时间。
  private static let confirmTimeout: TimeInterval = 1.5

  func turnOn(preferKeyboard: Bool, shortcut: String) -> Outcome {
    if preferKeyboard, let hotkey = Self.systemHotkey(), let active = Self.focusActive() {
      if active {
        FocusAutomationDebugLog.log("专注本来就开着,不动")
        ownedByUs = false
        return .alreadyOn
      }
      if Self.press(hotkey, expectActive: true) {
        ownedByUs = true
        return .done(via: "系统快捷键")
      }
      FocusAutomationDebugLog.log("系统快捷键按下后勿扰没打开,退回快捷指令")
    }
    if let error = FocusAutomationController.runShortcut(shortcut) {
      return .failed(error)
    }
    ownedByUs = true
    return .done(via: "快捷指令")
  }

  func turnOff(preferKeyboard: Bool, shortcut: String) -> Outcome {
    guard ownedByUs else { return .skipped }
    ownedByUs = false
    if preferKeyboard, let hotkey = Self.systemHotkey(), let active = Self.focusActive() {
      if !active {
        FocusAutomationDebugLog.log("勿扰已经被关掉了,不动")
        return .skipped
      }
      if Self.press(hotkey, expectActive: false) {
        return .done(via: "系统快捷键")
      }
      FocusAutomationDebugLog.log("系统快捷键按下后勿扰没关闭,退回快捷指令")
    }
    if let error = FocusAutomationController.runShortcut(shortcut) {
      return .failed(error)
    }
    return .done(via: "快捷指令")
  }

  // MARK: - 系统快捷键

  struct Hotkey {
    let keyCode: UInt16
    let flags: UInt64
  }

  /// 系统设置 → 键盘快捷键 → 调度中心 →「打开/关闭勿扰模式」(symbolic hotkey 175)。
  /// parameters = [字符, 键码, 修饰键];关掉了或没配返回 nil。
  static func systemHotkey() -> Hotkey? {
    guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
      .dictionary(forKey: "AppleSymbolicHotKeys"),
      let entry = hotkeys["175"] as? [String: Any],
      (entry["enabled"] as? Bool) == true,
      let value = entry["value"] as? [String: Any],
      let parameters = value["parameters"] as? [Int], parameters.count == 3,
      parameters[1] != 65535
    else { return nil }
    return Hotkey(keyCode: UInt16(parameters[1]), flags: UInt64(parameters[2]))
  }

  /// 按一下快捷键,等专注状态变成预期值;超时返回 false。
  private static func press(_ hotkey: Hotkey, expectActive: Bool) -> Bool {
    FocusAutomationDebugLog.log("按系统快捷键 keyCode=\(hotkey.keyCode) flags=\(hotkey.flags)")
    ShortcutSynthesizer.sendKey(keyCode: hotkey.keyCode, modifierFlags: hotkey.flags)
    let deadline = Date().addingTimeInterval(confirmTimeout)
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
      if focusActive(logging: false) == expectActive { return true }
    }
    return false
  }

  // MARK: - 专注状态

  /// 有没有手动打开的专注;读不了(没有完全磁盘访问权限)返回 nil。
  static func focusActive(logging: Bool = true) -> Bool? {
    guard let data = try? Data(contentsOf: assertionsURL) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let stores = json["data"] as? [[String: Any]]
    else {
      FocusAutomationDebugLog.log("专注状态文件格式认不出,顶层键: \((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.sorted() ?? [])")
      return nil
    }
    let records = stores.flatMap { $0["storeAssertionRecords"] as? [[String: Any]] ?? [] }
    if logging, FocusAutomationDebugLog.isEnabled {
      let modes = records.compactMap { ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }
      FocusAutomationDebugLog.log("专注状态: \(records.isEmpty ? "关" : "开 \(modes)")")
    }
    return !records.isEmpty
  }

  /// 设置页用:系统快捷键这条路为什么走不通;nil = 能用。
  static func keyboardUnavailableReason() -> String? {
    if systemHotkey() == nil {
      return "系统「打开/关闭勿扰模式」快捷键没开:系统设置 → 键盘 → 键盘快捷键 → 调度中心"
    }
    if focusActive() == nil {
      return "需要给 Velto「完全磁盘访问权限」才能读到勿扰现在开没开"
    }
    return nil
  }
}
