import CoreGraphics
import Foundation
import betterfinder

final class BetterFinderGlobalShortcutController: @unchecked Sendable {
    private var preferences = BetterFinderPreferencesStore.shared.preferences
    // 热键相关只在主线程读写(偏好同步在 main)。
    private var hotKeyPreferences: BetterFinderPreferences?
    private var hotKeys: [GlobalHotKey] = []

    func updatePreferences(_ preferences: BetterFinderPreferences) {
        self.preferences = preferences
        BetterFinderDebugLog.setEnabled(preferences.debugLoggingEnabled)
    }

    /// 主线程调用。安全输入开着时 tap 收不到 keyDown,靠热键兜底;增强 Finder 关着时不占组合键。
    func updateHotKeys(_ preferences: BetterFinderPreferences) {
        guard preferences != hotKeyPreferences else { return }
        hotKeyPreferences = preferences
        hotKeys = []
        guard preferences.isEnabled else { return }

        let shortcuts: [(BetterFinderShortcut?, BetterFinderQuickAction)] = [
            (preferences.openTerminalShortcut, .openDefaultTerminal),
            (preferences.openEditorShortcut, .openDefaultEditor),
            (preferences.copyPathShortcut, .copyPathToClipboard),
        ]
        hotKeys = shortcuts.compactMap { shortcut, action in
            guard let shortcut else { return nil }
            return GlobalHotKey(
                keyCode: shortcut.keyCode,
                modifierFlags: shortcut.modifierFlags,
                logFailure: { status in
                    BetterFinderDebugLog.log("hotkey register failed action=\(action.rawValue) status=\(status)")
                },
                action: { [weak self] in
                    self?.perform(action, preferences: preferences)
                }
            )
        }
    }

    func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
        guard preferences.isEnabled else {
            BetterFinderDebugLog.log("shortcut ignored reason=disabled")
            return false
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if matches(preferences.openTerminalShortcut, keyCode: keyCode, normalizedFlags: raw) {
            BetterFinderDebugLog.log("shortcut matched action=openDefaultTerminal keyCode=\(keyCode) flags=\(raw)")
            perform(.openDefaultTerminal, preferences: preferences)
            return true
        }
        if matches(preferences.openEditorShortcut, keyCode: keyCode, normalizedFlags: raw) {
            BetterFinderDebugLog.log("shortcut matched action=openDefaultEditor keyCode=\(keyCode) flags=\(raw)")
            perform(.openDefaultEditor, preferences: preferences)
            return true
        }
        if matches(preferences.copyPathShortcut, keyCode: keyCode, normalizedFlags: raw) {
            BetterFinderDebugLog.log("shortcut matched action=copyPathToClipboard keyCode=\(keyCode) flags=\(raw)")
            perform(.copyPathToClipboard, preferences: preferences)
            return true
        }
        return false
    }

    private func matches(
        _ shortcut: BetterFinderShortcut?,
        keyCode: UInt16,
        normalizedFlags raw: UInt64
    ) -> Bool {
        guard let shortcut else { return false }
        return shortcut.keyCode == keyCode && shortcut.modifierFlags == raw
    }

    private func perform(_ action: BetterFinderQuickAction, preferences: BetterFinderPreferences) {
        DispatchQueue.main.async {
            do {
                try BetterFinderActionRunner.performQuickAction(action, preferences: preferences)
                BetterFinderDebugLog.log("shortcut performed action=\(action.rawValue)")
            } catch {
                BetterFinderDebugLog.log("shortcut failed action=\(action.rawValue) error=\(error.localizedDescription)")
                DebugLog.event("betterfinder", [
                    "action": action.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }
    }
}
