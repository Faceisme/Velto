import AppKit
import Carbon
import CoreGraphics
import Foundation

private final class TemporaryInputWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// 输入法切换执行器:TISSelectInputSource + 必要时 CJKV 二次确认。
///
/// 切到 CJKV 输入法(中日韩越)常出现"菜单栏图标已变、实际还在英文"的半切换。
/// 修复思路借鉴 InputSourcePro(GPL-3.0,仅参考其行为,未复制源码):
///   先切目标 → 弹到一个非 CJKV 源(bounce) → 合成系统「选择上一个输入法」热键
///   切回目标(走 OS 热键路径能真正激活 CJKV)→ 轻点一次 Command → 末尾校验,
///   若仍未到位再 TISSelectInputSource 兜底。
/// 合成热键即便因系统对 Fn/Globe 等修饰键的限制而不生效,bounce + 末尾兜底也能保证
/// 最终停在目标输入法上 —— 这一层冗余是关键,不可省。
enum InputSourceSwitchSelector {
  /// 合成事件暗号 —— CJKV 修复会合成键盘事件,必须让 Velto 常驻 EventTapManager
  /// 认得并原样透传,不误触发手势/切换器/快捷键。取值与现有 marker 不同。"ISSFIX"。
  static let syntheticEventMarker: Int64 = 0x495353464958

  /// CJKV 修复各步之间的间隔。与参考实现一致,给系统留出处理热键/激活的时间。
  private static let cjkStepDelay: TimeInterval = 0.1

  /// 临时窗口策略的可见时长。够长到让 IME 在隐藏文本框里建立输入会话,又短到几乎无感。
  private static let temporaryWindowDuration: TimeInterval = 0.08

  /// 当前临时输入窗口及其弹出前的前台 app(关窗后还回)。仅主线程访问。
  @MainActor private static var temporaryWindow: NSWindow?
  @MainActor private static var temporaryWindowPreviousApp: NSRunningApplication?

  /// 切到指定持久化 ID 的输入法。返回是否成功发起切换(同步发起即算成功,
  /// CJKV 修复的后续步骤异步进行)。
  @discardableResult
  static func select(
    persistentID: String,
    cjkFixEnabled: Bool,
    cjkFixStrategy: InputSourceCJKFixStrategy
  ) -> Bool {
    guard let target = InputSourceCatalog.tisInputSource(forID: persistentID) else {
      InputSourceSwitchDebugLog.log("select FAILED: 找不到输入源 id=\(persistentID)")
      return false
    }

    let isCJKV = InputSourceCatalog.all().first { $0.id == persistentID }?.isCJKV ?? false
    // 非 CJKV,或用户关闭了修复:直接选,选完即止。
    guard cjkFixEnabled, isCJKV else {
      return plainSelect(target, id: persistentID)
    }

    switch cjkFixStrategy {
    case .previousInputSourceShortcut:
      return switchCJKVWithPreviousShortcut(target: target, targetID: persistentID)
    case .temporaryInputWindow:
      let ok = plainSelect(target, id: persistentID)
      Task { @MainActor in runTemporaryInputWindow(targetID: persistentID) }
      return ok
    }
  }

  /// 纯 TISSelectInputSource。
  @discardableResult
  private static func plainSelect(_ source: TISInputSource, id: String) -> Bool {
    let status = TISSelectInputSource(source)
    guard status == noErr else {
      InputSourceSwitchDebugLog.log("select FAILED: TISSelectInputSource status=\(status) id=\(id)")
      return false
    }
    InputSourceSwitchDebugLog.log("select OK id=\(id)")
    return true
  }

  // MARK: - CJKV 修复:bounce + 选上一个 + Command 轻点 + 兜底重选

  private static func switchCJKVWithPreviousShortcut(target: TISInputSource, targetID: String) -> Bool {
    guard let bounce = nonCJKVBounceSource(excluding: targetID) else {
      // 没有可用的非 CJKV 源做 bounce(用户只装了 CJKV 输入法):退化为纯切换。
      InputSourceSwitchDebugLog.log("cjk-fix SKIP: 无非 CJKV 源可 bounce,直接选 id=\(targetID)")
      return plainSelect(target, id: targetID)
    }

    // 1) 先切目标(同步返回 true 表示已发起);2) 立刻弹到非 CJKV 源。
    //    这样系统「上一个输入法」指针就指向目标,后面合成热键才能切回目标。
    let ok = plainSelect(target, id: targetID)
    _ = TISSelectInputSource(bounce.source)
    InputSourceSwitchDebugLog.log("cjk-fix bounce → \(bounce.id)")

    let shortcut = previousInputSourceShortcut()
    // 3) 合成「选择上一个输入法」热键,走 OS 路径切回目标并激活 CJKV。
    DispatchQueue.main.asyncAfter(deadline: .now() + cjkStepDelay) {
      if let shortcut {
        InputSourceSwitchDebugLog.log("cjk-fix 合成「选上一个」keyCode=\(shortcut.keyCode)")
        synthesize(keyCode: shortcut.keyCode, flags: shortcut.flags)
      } else {
        InputSourceSwitchDebugLog.log("cjk-fix 无「选上一个」热键,靠末尾兜底重选")
      }
      // 4) 轻点一次 Command,促使系统确认输入源切换。
      DispatchQueue.main.asyncAfter(deadline: .now() + cjkStepDelay) {
        synthesizeCommandTap()
        // 5) 末尾校验:仍未停在目标就再 TIS 兜底。重新按 ID 解析句柄,
        //    避免把非 Sendable 的 TISInputSource 跨异步边界捕获(Swift 6 并发)。
        DispatchQueue.main.asyncAfter(deadline: .now() + cjkStepDelay) {
          if InputSourceCatalog.current()?.id == targetID {
            InputSourceSwitchDebugLog.log("cjk-fix 完成,当前=\(targetID)")
          } else if let again = InputSourceCatalog.tisInputSource(forID: targetID) {
            InputSourceSwitchDebugLog.log("cjk-fix 兜底重选 → \(targetID)")
            _ = TISSelectInputSource(again)
          }
        }
      }
    }
    return ok
  }

  /// 找一个非 CJKV 的可选中输入源做 bounce(排除目标自身)。优先用"当前源"——
  /// 通常它就是即将离开的非 CJKV 源(如 US),bounce 最自然、视觉跳动最小。
  private static func nonCJKVBounceSource(excluding targetID: String) -> (id: String, source: TISInputSource)? {
    if let current = InputSourceCatalog.current(), !current.isCJKV, current.id != targetID,
       let source = InputSourceCatalog.tisInputSource(forID: current.id) {
      return (current.id, source)
    }
    guard let info = InputSourceCatalog.all().first(where: { !$0.isCJKV && $0.id != targetID }),
          let source = InputSourceCatalog.tisInputSource(forID: info.id)
    else { return nil }
    return (info.id, source)
  }

  /// 读 com.apple.symbolichotkeys 里 id 60「选择上一个输入法」的快捷键。
  /// 未启用 / 不存在 → nil(合成步骤跳过,改由末尾兜底保证最终落在目标上)。
  static func previousInputSourceShortcut() -> (keyCode: UInt16, flags: CGEventFlags)? {
    guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
          let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys"),
          let entry = hotkeys["60"] as? [String: Any],
          (entry["enabled"] as? Bool) == true,
          let value = entry["value"] as? [String: Any],
          let parameters = value["parameters"] as? [Any],
          parameters.count >= 3,
          let keyCode = intValue(parameters[1]),
          let modifierRaw = intValue(parameters[2])
    else { return nil }

    return (UInt16(keyCode), cgFlags(fromNSModifierRaw: UInt(modifierRaw)))
  }

  private static func intValue(_ value: Any) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }

  /// symbolichotkeys 的 modifier 字段是 NSEvent.ModifierFlags 的 raw 值。
  /// **刻意不处理 Fn/Globe 位(1<<23)**:新机型默认把「选上一个输入法」绑到 🌐 键。
  /// 若把 Fn 合进去,合成热键会真的生效、经"系统热键路径"激活 CJKV 输入法 ——
  /// 这样激活的输入法会变"粘",后续 TISSelectInputSource 切回英文切不走它。
  /// 与 InputSourcePro 行为一致:Fn 一律忽略,让该机型上的合成热键退化为空操作,
  /// CJKV 输入法最终由末尾的 TIS 兜底重选激活(TIS 激活的不粘,可正常切走)。
  private static func cgFlags(fromNSModifierRaw raw: UInt) -> CGEventFlags {
    var flags = CGEventFlags()
    if raw & 131_072 != 0 { flags.insert(.maskShift) }
    if raw & 262_144 != 0 { flags.insert(.maskControl) }
    if raw & 524_288 != 0 { flags.insert(.maskAlternate) }
    if raw & 1_048_576 != 0 { flags.insert(.maskCommand) }
    return flags
  }

  /// 合成一组带暗号的按键事件(仿 ShortcutSynthesizer,但用本模块自己的 marker)。
  @discardableResult
  private static func synthesize(keyCode: UInt16, flags: CGEventFlags) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      InputSourceSwitchDebugLog.log("cjk-fix FAILED: CGEventSource unavailable keyCode=\(keyCode)")
      return false
    }
    let key = CGKeyCode(keyCode)

    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else {
      InputSourceSwitchDebugLog.log("cjk-fix FAILED: keyDown event creation failed keyCode=\(keyCode)")
      return false
    }
    down.flags = flags
    down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)

    guard let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
      InputSourceSwitchDebugLog.log("cjk-fix FAILED: keyUp event creation failed keyCode=\(keyCode)")
      return false
    }
    up.flags = flags
    up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)

    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  /// 轻点一次 Command 键(down 带 .maskCommand,up 清空),促使系统确认输入源切换。
  private static func synthesizeCommandTap() {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let cmd = CGKeyCode(kVK_Command)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
    else { return }
    down.flags = .maskCommand
    up.flags = []
    down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  /// 临时输入窗口策略(完全照 macism / InputSourcePro 的行为实现,未复制 GPL 源码):
  /// TIS 选中目标后,在屏幕角落弹一个近乎全透明、装着 NSTextView 的 3x3 窗口,令其成为
  /// key 并 **激活 Velto**(`NSApp.activate`),逼 macOS 围绕这个文本框为目标 IME 真正
  /// 建立输入会话 —— 把"菜单栏图标已变、实际仍打英文"的半切换态扶正成中文态,随即关窗、
  /// 把焦点还给原前台 app。因为目标仍是 TIS 选中的,不会像系统热键那样"粘住"、可正常切走。
  ///
  /// **必须激活**:只让窗口成为 key 而不激活 app(非激活面板)时,IME 的输入客户端仍在
  /// 原 app 上,隐藏文本框拿不到能重置 CJKV 子模式的真实输入会话,半切换扶不正。激活带来
  /// 的瞬时焦点跳动是这套可靠方案固有的代价(IPS 亦然)。
  @MainActor
  private static func runTemporaryInputWindow(targetID: String) {
    closeTemporaryWindow(restorePrevious: false)
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

    temporaryWindowPreviousApp = NSWorkspace.shared.frontmostApplication

    let size = NSSize(width: 3, height: 3)
    let visible = screen.visibleFrame
    let rect = NSRect(
      x: visible.maxX - size.width - 8,
      y: visible.minY + 8,
      width: size.width,
      height: size.height
    )
    let window = TemporaryInputWindow(
      contentRect: rect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
    window.contentView = textView
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.alphaValue = 0.01
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    temporaryWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(textView)
    InputSourceSwitchDebugLog.log("cjk-fix 临时窗口已弹出")

    DispatchQueue.main.asyncAfter(deadline: .now() + temporaryWindowDuration) {
      closeTemporaryWindow(restorePrevious: true)
    }
    // 关窗后校验(对齐 IPS 的 duration + 0.05):没停在目标就 TIS 兜底重选。
    DispatchQueue.main.asyncAfter(deadline: .now() + temporaryWindowDuration + 0.05) {
      if InputSourceCatalog.current()?.id == targetID {
        InputSourceSwitchDebugLog.log("cjk-fix 临时窗口完成,当前=\(targetID)")
      } else if let again = InputSourceCatalog.tisInputSource(forID: targetID) {
        InputSourceSwitchDebugLog.log("cjk-fix 临时窗口兜底重选 → \(targetID)")
        _ = TISSelectInputSource(again)
      }
    }
  }

  /// 关闭临时窗口;`restorePrevious` 时把焦点还给弹窗前的前台 app。
  /// 仅当焦点确实还在 Velto 上、且原 app 不是 Velto 自己时才还回,避免误抢。
  @MainActor
  private static func closeTemporaryWindow(restorePrevious: Bool) {
    guard let window = temporaryWindow else {
      temporaryWindowPreviousApp = nil
      return
    }
    temporaryWindow = nil
    window.orderOut(nil)
    window.close()

    let previous = temporaryWindowPreviousApp
    temporaryWindowPreviousApp = nil
    guard restorePrevious, let previous,
          previous.bundleIdentifier != Bundle.main.bundleIdentifier,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    else { return }
    previous.activate(options: [])
  }
}
