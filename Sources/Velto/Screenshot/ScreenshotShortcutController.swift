import CoreGraphics
import Foundation

/// tap 线程匹配截图全局触发键。匹配后切主线程启动会话,返回 true 吞掉事件。
/// 触发键另注册成 `GlobalHotKey`,安全输入开着时靠它兜底。
final class ScreenshotShortcutController: @unchecked Sendable {
  private let lock = NSLock()
  private var triggerShortcut: Shortcut?
  // 热键相关只在主线程读写(偏好同步在 main)。
  private var hotKeyShortcut: Shortcut?
  private var hotKey: GlobalHotKey?

  /// 主线程调用。传 nil = 不占触发键(截图关着时别抢别人的组合键)。
  func updateShortcut(_ shortcut: Shortcut?) {
    lock.lock(); triggerShortcut = shortcut; lock.unlock()
    guard shortcut != hotKeyShortcut else { return }
    hotKeyShortcut = shortcut
    hotKey = nil
    guard let shortcut else { return }
    hotKey = GlobalHotKey(
      keyCode: shortcut.keyCode,
      modifierFlags: shortcut.modifierFlags,
      logFailure: { status in
        ScreenshotDebugLog.log("安全输入兜底热键注册失败 status=\(status) shortcut=\(shortcut.displayName)")
      },
      action: {
        DispatchQueue.main.async {
          ScreenshotController.shared.beginSession()
          // 记在 beginSession 之后:日志开关是它按偏好打开的,刚启动时先记会被吞。
          ScreenshotDebugLog.log("↑ 触发键走的 Carbon 兜底(安全输入开着,tap 收不到 keyDown)")
        }
      }
    )
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
