import CoreGraphics
import Foundation

/// tap 线程匹配截图全局触发键。匹配后切主线程启动会话,返回 true 吞掉事件。
final class ScreenshotShortcutController: @unchecked Sendable {
  private let lock = NSLock()
  private var triggerShortcut: Shortcut?

  func updateShortcut(_ shortcut: Shortcut?) {
    lock.lock(); triggerShortcut = shortcut; lock.unlock()
  }

  func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
    lock.lock(); let shortcut = triggerShortcut; lock.unlock()
    guard let shortcut else { return false }
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == shortcut.keyCode, raw == shortcut.modifierFlags else { return false }
    DispatchQueue.main.async { ScreenshotController.shared.beginSession() }
    return true
  }
}
