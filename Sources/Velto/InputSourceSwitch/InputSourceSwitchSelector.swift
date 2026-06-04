import AppKit
import Carbon
import CoreGraphics
import Foundation

/// 输入法切换执行器:TISSelectInputSource + 必要时 CJKV 二次确认。
enum InputSourceSwitchSelector {
    /// 合成事件暗号 —— previousInputSourceShortcut 策略会合成键盘事件,
    /// 必须让 Velto 常驻 EventTapManager 认得并原样透传,不误触发手势/切换器/快捷键。
    /// 取值与现有 marker 不同。"ISSFIX"。
    static let syntheticEventMarker: Int64 = 0x495353464958

    /// 切到指定持久化 ID 的输入法。返回是否成功发起切换。
    @discardableResult
    static func select(
        persistentID: String,
        cjkFixEnabled: Bool,
        cjkFixStrategy: InputSourceCJKFixStrategy
    ) -> Bool {
        guard let source = InputSourceCatalog.tisInputSource(forID: persistentID) else {
            InputSourceSwitchDebugLog.log("select FAILED: 找不到输入源 id=\(persistentID)")
            return false
        }

        let status = TISSelectInputSource(source)
        guard status == noErr else {
            InputSourceSwitchDebugLog.log("select FAILED: TISSelectInputSource status=\(status) id=\(persistentID)")
            return false
        }

        InputSourceSwitchDebugLog.log("select OK id=\(persistentID)")
        let isCJKV = InputSourceCatalog.all().first { $0.id == persistentID }?.isCJKV ?? false
        if cjkFixEnabled && isCJKV {
            applyCJKFix(strategy: cjkFixStrategy)
        }
        return true
    }

    // MARK: - CJKV 修复

    private static func applyCJKFix(strategy: InputSourceCJKFixStrategy) {
        switch strategy {
        case .previousInputSourceShortcut:
            guard let shortcut = previousInputSourceShortcut() else {
                InputSourceSwitchDebugLog.log("cjk-fix SKIP: 系统未配置「选择上一个输入法」快捷键")
                return
            }
            InputSourceSwitchDebugLog.log("cjk-fix previousShortcut keyCode=\(shortcut.keyCode)")
            synthesize(keyCode: shortcut.keyCode, flags: shortcut.flags)

        case .temporaryInputWindow:
            InputSourceSwitchDebugLog.log("cjk-fix temporaryWindow")
            Task { @MainActor in
                showTemporaryInputWindow()
            }
        }
    }

    /// 读 com.apple.symbolichotkeys 里 id 60「选择上一个输入法」的快捷键。
    /// 未启用 / 不存在 → nil(UI 据此提示去键盘设置)。
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
    private static func cgFlags(fromNSModifierRaw raw: UInt) -> CGEventFlags {
        var flags = CGEventFlags()
        if raw & 131_072 != 0 { flags.insert(.maskShift) }
        if raw & 262_144 != 0 { flags.insert(.maskControl) }
        if raw & 524_288 != 0 { flags.insert(.maskAlternate) }
        if raw & 1_048_576 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    /// 合成一组带暗号的按键事件(仿 ShortcutSynthesizer,但用本模块自己的 marker)。
    private static func synthesize(keyCode: UInt16, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let key = CGKeyCode(keyCode)

        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)

        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 透明 3x3 临时窗口:短暂抢焦点逼 macOS 重新确认输入上下文,再还回前台 app。
    /// 仅在用户显式选 temporaryInputWindow 时走。
    @MainActor
    private static func showTemporaryInputWindow() {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: -10, y: -10, width: 3, height: 3),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .popUpMenu
        window.alphaValue = 0.0
        window.ignoresMouseEvents = true

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 3, height: 3))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            window.orderOut(nil)
            previousApp?.activate()
        }
    }
}
