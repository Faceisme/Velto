import Foundation

/// 用 `hidutil` 在 HID 驱动层做按键重映射 —— 专治 Caps Lock 这类「toggle 源」。
///
/// 为什么不能在 event tap 里做:tap 消费 caps 的 flagsChanged 拦不住 HID 层的物理
/// toggle,LED 会先亮再被按灭 = 肉眼可见的「闪一下」。只有在 HID 层把 caps 直接改成
/// 目标键,它才从一开始就不是 caps(不亮灯、不 toggle),这正是系统设置→修饰键、
/// Karabiner 的简单 key→key 同源做法。
///
/// 作用域与生命周期:
/// - `UserKeyMapping` 是「当前登录会话」级别的全局映射,注销 / 重启即清零。
/// - 本类独占这份映射(`--set` 会整体替换 hidutil 的 UserKeyMapping 列表),只放
///   Velto 需要的 caps 重映射;不与其它工具共存(会互相覆盖)。
/// - 启动 / 规则变更时整体重设;退出时 `resetSync()` 清空,让 caps 复原。崩溃残留会
///   在下次启动被重设,或注销 / 重启后消失。
enum KeyRemapHIDRemap {
  struct HIDPair: Equatable {
    let src: UInt64   // 完整 HID usage,如 caps = 0x700000039
    let dst: UInt64
  }

  private static let queue = DispatchQueue(label: "com.velto.keyremap.hidremap")
  // 仅在 queue 内触碰。
  private nonisolated(unsafe) static var lastApplied: [HIDPair] = []

  /// macOS 虚拟 keyCode → 完整 HID usage(usage page 0x07 | id)。
  /// fn / vk_none 等无对应 → nil(hidutil 不处理,留给反应式回退或直接跳过)。
  static func hidUsage(forKeyCode keyCode: UInt16) -> UInt64? {
    guard let name = KeyCodeMap.byKeyCode[keyCode]?.karabinerName,
          let id = usageByName[name] else { return nil }
    return 0x700000000 | UInt64(id)
  }

  /// 整体设置映射(替换上一次)。与上次相同则跳过(幂等)。在后台串行队列执行,
  /// 不阻塞调用线程(主线程)。
  static func setMappings(_ pairs: [HIDPair]) {
    queue.async {
      guard pairs != lastApplied else { return }
      lastApplied = pairs
      run(pairs: pairs)
    }
  }

  /// 同步清空(caps 复原)。供 applicationWillTerminate 调用 —— 必须在进程退出前
  /// 真正跑完 hidutil,故同步阻塞(~几十毫秒,可接受)。
  static func resetSync() {
    queue.sync { lastApplied = [] }
    run(pairs: [])
  }

  private static func run(pairs: [HIDPair]) {
    let items = pairs.map {
      "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
    }.joined(separator: ",")
    let json = "{\"UserKeyMapping\":[\(items)]}"

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--set", json]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = Pipe()
    do {
      try p.run()
      p.waitUntilExit()
      if p.terminationStatus == 0 {
        KeyRemapDebugLog.log("hidutil 应用成功:\(pairs.isEmpty ? "已清空(caps 复原)" : json)")
      } else {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        KeyRemapDebugLog.log("hidutil 应用失败 status=\(p.terminationStatus) err=\(err) json=\(json)")
      }
    } catch {
      KeyRemapDebugLog.log("hidutil 启动失败:\(error)")
    }
  }

  // USB HID Usage Table,Keyboard/Keypad(usage page 0x07)。键名对齐 KeyCodeMap。
  private static let usageByName: [String: UInt32] = [
    "a": 0x04, "b": 0x05, "c": 0x06, "d": 0x07, "e": 0x08, "f": 0x09, "g": 0x0A,
    "h": 0x0B, "i": 0x0C, "j": 0x0D, "k": 0x0E, "l": 0x0F, "m": 0x10, "n": 0x11,
    "o": 0x12, "p": 0x13, "q": 0x14, "r": 0x15, "s": 0x16, "t": 0x17, "u": 0x18,
    "v": 0x19, "w": 0x1A, "x": 0x1B, "y": 0x1C, "z": 0x1D,
    "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22,
    "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
    "return_or_enter": 0x28, "escape": 0x29, "delete_or_backspace": 0x2A,
    "tab": 0x2B, "spacebar": 0x2C, "delete_forward": 0x4C,
    "home": 0x4A, "end": 0x4D, "page_up": 0x4B, "page_down": 0x4E,
    "hyphen": 0x2D, "equal_sign": 0x2E, "open_bracket": 0x2F, "close_bracket": 0x30,
    "backslash": 0x31, "semicolon": 0x33, "quote": 0x34,
    "grave_accent_and_tilde": 0x35, "comma": 0x36, "period": 0x37, "slash": 0x38,
    "caps_lock": 0x39,
    "f1": 0x3A, "f2": 0x3B, "f3": 0x3C, "f4": 0x3D, "f5": 0x3E, "f6": 0x3F,
    "f7": 0x40, "f8": 0x41, "f9": 0x42, "f10": 0x43, "f11": 0x44, "f12": 0x45,
    "f13": 0x68, "f14": 0x69, "f15": 0x6A, "f16": 0x6B, "f17": 0x6C, "f18": 0x6D,
    "f19": 0x6E, "f20": 0x6F,
    "right_arrow": 0x4F, "left_arrow": 0x50, "down_arrow": 0x51, "up_arrow": 0x52,
    "left_control": 0xE0, "left_shift": 0xE1, "left_option": 0xE2, "left_command": 0xE3,
    "right_control": 0xE4, "right_shift": 0xE5, "right_option": 0xE6, "right_command": 0xE7,
  ]
}
