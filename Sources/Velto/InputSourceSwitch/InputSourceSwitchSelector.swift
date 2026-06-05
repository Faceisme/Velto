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
/// 修复流程对齐 InputSourcePro 的无抢焦点路径(仅参考行为,未复制源码):
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
  private static let temporaryWindowDuration: TimeInterval = 0.08
  private static let temporaryWindowActivationSuppressionDuration: TimeInterval = 0.5

  @MainActor private static var pendingWorkItems: [DispatchWorkItem] = []
  @MainActor private static var temporaryWindow: NSWindow?
  @MainActor private static var temporaryWindowPreviousApp: NSRunningApplication?
  @MainActor private static var temporaryWindowActivationSuppressionEndTime: TimeInterval = 0
  @MainActor private static var isShowingTemporaryWindow = false

  /// 合成键盘事件的抑制窗口。部分 flagsChanged 事件不一定保留 userData,用 PID + 时间兜底。
  private nonisolated(unsafe) static var syntheticEventEndTime: TimeInterval = 0

  @MainActor
  static var isHandlingTemporaryWindowActivation: Bool {
    isShowingTemporaryWindow ||
      ProcessInfo.processInfo.systemUptime < temporaryWindowActivationSuppressionEndTime
  }

  @MainActor
  static func isTemporaryWindowApplicationActivation(_ app: NSRunningApplication) -> Bool {
    guard isHandlingTemporaryWindowActivation else { return false }
    return app.bundleIdentifier == Bundle.main.bundleIdentifier
  }

  static func isSyntheticEvent(_ event: CGEvent?) -> Bool {
    guard let event else { return false }
    if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
      return true
    }
    let eventPID = event.getIntegerValueField(.eventSourceUnixProcessID)
    return ProcessInfo.processInfo.systemUptime < syntheticEventEndTime
      && eventPID == Int64(ProcessInfo.processInfo.processIdentifier)
  }

  /// 切到指定持久化 ID 的输入法。返回是否成功发起切换(同步发起即算成功,
  /// CJKV 修复的后续步骤异步进行)。
  @discardableResult
  @MainActor
  static func select(
    persistentID: String,
    cjkFixEnabled: Bool,
    cjkFixStrategy: InputSourceCJKFixStrategy
  ) -> Bool {
    cancelPendingWorkItems()
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
      return switchCJKVWithTemporaryWindow(target: target, targetID: persistentID)
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

  @MainActor
  private static func switchCJKVWithPreviousShortcut(target: TISInputSource, targetID: String) -> Bool {
    guard let shortcut = previousInputSourceShortcut(),
          let bounce = nonCJKVBounceSource(excluding: targetID)
    else {
      InputSourceSwitchDebugLog.log("cjk-fix shortcut fallback: 无快捷键或无非 CJKV 源,直接选 id=\(targetID)")
      return plainSelect(target, id: targetID)
    }

    // 1) 先切目标(同步返回 true 表示已发起);2) 立刻弹到非 CJKV 源。
    //    这样系统「上一个输入法」指针就指向目标,后面合成热键才能切回目标。
    syntheticEventEndTime = ProcessInfo.processInfo.systemUptime + 0.35
    let ok = plainSelect(target, id: targetID)
    _ = TISSelectInputSource(bounce.source)
    InputSourceSwitchDebugLog.log("cjk-fix bounce → \(bounce.id)")

    // 3) 合成「选择上一个输入法」热键,走 OS 路径切回目标并激活 CJKV。
    scheduleWorkItem(after: cjkStepDelay) {
      InputSourceSwitchDebugLog.log("cjk-fix 合成「选上一个」keyCode=\(shortcut.keyCode)")
      synthesize(keyCode: shortcut.keyCode, flags: shortcut.flags)
    }
    // 4) 轻点一次 Command,促使系统确认输入源切换。
    scheduleWorkItem(after: cjkStepDelay * 2) {
      synthesizeCommandTap()
    }
    // 5) 末尾校验:仍未停在目标就再 TIS 兜底。重新按 ID 解析句柄,
    //    避免把非 Sendable 的 TISInputSource 跨异步边界捕获(Swift 6 并发)。
    scheduleWorkItem(after: cjkStepDelay * 3) {
      if InputSourceCatalog.current()?.id == targetID {
        InputSourceSwitchDebugLog.log("cjk-fix 完成,当前=\(targetID)")
      } else if let again = InputSourceCatalog.tisInputSource(forID: targetID) {
        InputSourceSwitchDebugLog.log("cjk-fix 兜底重选 → \(targetID)")
        _ = TISSelectInputSource(again)
      }
    }
    return ok
  }

  @MainActor
  private static func switchCJKVWithTemporaryWindow(target: TISInputSource, targetID: String) -> Bool {
    let ok = plainSelect(target, id: targetID)
    runTemporaryInputWindow(targetID: targetID)
    scheduleWorkItem(after: temporaryWindowDuration + 0.05) {
      if InputSourceCatalog.current()?.id == targetID {
        InputSourceSwitchDebugLog.log("cjk-fix 临时窗口完成,当前=\(targetID)")
      } else if let again = InputSourceCatalog.tisInputSource(forID: targetID) {
        InputSourceSwitchDebugLog.log("cjk-fix 临时窗口兜底重选 → \(targetID)")
        _ = TISSelectInputSource(again)
      }
    }
    return ok
  }

  /// 找一个非 CJKV 的可选中输入源做 bounce(排除目标自身)。对齐 InputSourcePro:
  /// 使用输入源列表里的第一个非 CJKV 可选源。
  private static func nonCJKVBounceSource(excluding targetID: String) -> (id: String, source: TISInputSource)? {
    guard let info = InputSourceCatalog.all().first(where: { !$0.isCJKV && $0.isEnabled && $0.id != targetID }),
          let source = InputSourceCatalog.tisInputSource(forID: info.id)
    else { return nil }
    return (info.id, source)
  }

  /// 读 com.apple.symbolichotkeys 里 id 60「选择上一个输入法」的快捷键。
  /// 未启用 / 不存在 → nil(退化为纯 TISSelectInputSource)。
  static func previousInputSourceShortcut() -> (keyCode: UInt16, flags: CGEventFlags)? {
    guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
          let hotkeys = domain["AppleSymbolicHotKeys"] as? [String: Any],
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
    suppressTemporaryWindowActivation()
    isShowingTemporaryWindow = true

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(textView)
    InputSourceSwitchDebugLog.log("cjk-fix 临时窗口已弹出")

    scheduleWorkItem(after: temporaryWindowDuration) {
      closeTemporaryWindow(restorePrevious: true)
    }
  }

  @MainActor
  private static func closeTemporaryWindow(restorePrevious: Bool) {
    guard let window = temporaryWindow else {
      temporaryWindowPreviousApp = nil
      isShowingTemporaryWindow = false
      return
    }
    temporaryWindow = nil
    window.orderOut(nil)
    window.close()
    suppressTemporaryWindowActivation()
    isShowingTemporaryWindow = false

    let previous = temporaryWindowPreviousApp
    temporaryWindowPreviousApp = nil
    guard restorePrevious, let previous,
          previous.bundleIdentifier != Bundle.main.bundleIdentifier,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    else { return }
    previous.activate(options: [])
  }

  @MainActor
  private static func cancelPendingWorkItems() {
    syntheticEventEndTime = 0
    closeTemporaryWindow(restorePrevious: true)
    pendingWorkItems.forEach { $0.cancel() }
    pendingWorkItems.removeAll()
  }

  @MainActor
  private static func scheduleWorkItem(after delay: TimeInterval, execute work: @escaping () -> Void) {
    var workItem: DispatchWorkItem?
    workItem = DispatchWorkItem {
      guard let item = workItem else { return }
      MainActor.assumeIsolated {
        defer { removePendingWorkItem(item) }
        guard !item.isCancelled else { return }
        work()
      }
    }
    guard let item = workItem else { return }
    pendingWorkItems.append(item)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  @MainActor
  private static func removePendingWorkItem(_ item: DispatchWorkItem) {
    if let index = pendingWorkItems.firstIndex(where: { $0 === item }) {
      pendingWorkItems.remove(at: index)
    }
  }

  @MainActor
  private static func suppressTemporaryWindowActivation() {
    temporaryWindowActivationSuppressionEndTime =
      ProcessInfo.processInfo.systemUptime + temporaryWindowActivationSuppressionDuration
  }

}
