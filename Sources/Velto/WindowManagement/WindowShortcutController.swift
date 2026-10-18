import AppKit
import CoreGraphics
import Foundation

/// Currently handles the single "maximize window under pointer" action — 由键盘
/// 快捷键或鼠标按钮触发 — but kept as its own type so future window-related global
/// shortcuts (move-to-half, next-screen, etc.) can slot in here without re-bloating
/// EventTapManager.
/// `@unchecked Sendable`:`handleKeyDown` / 鼠标按钮入口在 tap 线程上,`update*`
/// 在主线程上,内部用 `lock` 保护快照;`heldButtons` 只在 tap 线程读写。
final class WindowShortcutController: @unchecked Sendable {
    private let lock = NSLock()
    private var maximizeShortcut: Shortcut?
    private var maximizeButton: MouseButtonTrigger?
    /// 最大化鼠标按钮不接管的 App(bundle id)。
    private var maximizeButtonExcludedApps: Set<String> = []
    /// 按下时被吞掉、还没抬起的按钮号;对应的 dragged / up 也要一并认领。
    private var heldButtons: Set<Int64> = []

    func updateShortcut(_ shortcut: Shortcut?) {
        lock.lock()
        maximizeShortcut = shortcut
        lock.unlock()
    }

    func updateMaximizeButton(_ trigger: MouseButtonTrigger?, excludedApps: Set<String> = []) {
        lock.lock()
        maximizeButton = trigger
        maximizeButtonExcludedApps = excludedApps
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

        maximize(at: event.location)
        return true
    }

    /// 鼠标按钮按下(tap 线程):命中「最大化鼠标按钮」就吞掉并最大化光标下的窗口。
    /// 光标下是例外 App(它自己要用这个按钮)或 Velto 自己的窗口(设置页录按钮)时放行。
    func handleMouseDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
        lock.lock()
        let trigger = maximizeButton
        let excludedApps = maximizeButtonExcludedApps
        lock.unlock()

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let trigger,
              Int(button) == trigger.button,
              raw == trigger.modifierFlags else { return false }
        let ownerBundleID = GestureAppScope.targetBundleIdentifier(
            policy: .windowUnderPointer,
            windowNumber: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            targetPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)),
            frontmostApplication: nil
        )
        guard ownerBundleID != Bundle.main.bundleIdentifier,
              !(ownerBundleID.map(excludedApps.contains) ?? false) else { return false }

        heldButtons.insert(button)
        maximize(at: event.location)
        return true
    }

    /// 按钮抬起:按下时吞过的才吞。不看开关 —— 按住期间关掉窗口管理,抬起也得一并吞掉。
    func handleMouseUp(button: Int64) -> Bool {
        heldButtons.remove(button) != nil
    }

    func isHoldingButton(_ button: Int64) -> Bool {
        heldButtons.contains(button)
    }

    /// tap 被系统禁用期间 up 会丢,清掉记账,免得之后那颗按钮透传时 up 被误吞。
    func resetTransientState() {
        heldButtons.removeAll()
    }

    private func maximize(at point: CGPoint) {
        DispatchQueue.global(qos: .userInteractive).async {
            GestureTargetController.maximizeWindowUnderPointer(at: point)
        }
    }

    private func matches(event: CGEvent, shortcut: Shortcut, normalizedFlags raw: UInt64) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return keyCode == shortcut.keyCode && raw == shortcut.modifierFlags
    }
}
