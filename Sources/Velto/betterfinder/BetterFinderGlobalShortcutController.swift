import CoreGraphics
import Foundation
import betterfinder

final class BetterFinderGlobalShortcutController: @unchecked Sendable {
    private var preferences = BetterFinderPreferencesStore.shared.preferences

    func updatePreferences(_ preferences: BetterFinderPreferences) {
        self.preferences = preferences
        BetterFinderDebugLog.setEnabled(preferences.debugLoggingEnabled)
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
            perform(.openDefaultTerminal)
            return true
        }
        if matches(preferences.openEditorShortcut, keyCode: keyCode, normalizedFlags: raw) {
            BetterFinderDebugLog.log("shortcut matched action=openDefaultEditor keyCode=\(keyCode) flags=\(raw)")
            perform(.openDefaultEditor)
            return true
        }
        if matches(preferences.copyPathShortcut, keyCode: keyCode, normalizedFlags: raw) {
            BetterFinderDebugLog.log("shortcut matched action=copyPathToClipboard keyCode=\(keyCode) flags=\(raw)")
            perform(.copyPathToClipboard)
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

    private func perform(_ action: BetterFinderQuickAction) {
        let snapshot = preferences
        DispatchQueue.main.async {
            do {
                try BetterFinderActionRunner.performQuickAction(action, preferences: snapshot)
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
