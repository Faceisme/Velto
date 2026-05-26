import CoreGraphics
import Foundation

/// Currently handles the single "maximize window under pointer" shortcut, but
/// kept as its own type so future window-related global shortcuts (move-to-half,
/// next-screen, etc.) can slot in here without re-bloating EventTapManager.
/// `@unchecked Sendable`:`handleKeyDown` 在 tap 线程上,`updateShortcut`
/// 在主线程上,内部用 `lock` 保护快照。
final class WindowShortcutController: @unchecked Sendable {
    private let lock = NSLock()
    private var maximizeShortcut: Shortcut?

    func updateShortcut(_ shortcut: Shortcut?) {
        lock.lock()
        maximizeShortcut = shortcut
        lock.unlock()
    }

    /// Tap-thread entry. Returns `true` if the event was consumed.
    func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
        lock.lock()
        let shortcut = maximizeShortcut
        lock.unlock()

        guard let shortcut else { return false }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        guard matches(event: event, shortcut: shortcut, normalizedFlags: raw) else { return false }

        let point = event.location
        DispatchQueue.global(qos: .userInteractive).async {
            GestureTargetController.maximizeWindowUnderPointer(at: point)
        }
        return true
    }

    private func matches(event: CGEvent, shortcut: Shortcut, normalizedFlags raw: UInt64) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return keyCode == shortcut.keyCode && raw == shortcut.modifierFlags
    }
}
