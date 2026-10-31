import AppKit
import XCTest
@testable import Velto

@MainActor
final class ScreenCleanControllerTests: XCTestCase {
  func testOnlyUnlockShortcutMatches() {
    let flags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    let unlock = Shortcut(keyCode: 37, modifierFlags: flags.rawValue, displayName: "⌃⌥⌘L")
    func matches(_ keyCode: UInt16, _ flags: CGEventFlags) -> Bool {
      ScreenCleanController.isUnlock(
        keyCode: keyCode, modifiers: ModifierFormatter.normalizedRawValue(from: flags), shortcut: unlock
      )
    }

    XCTAssertFalse(matches(0, []), "别的键")
    XCTAssertFalse(matches(unlock.keyCode, []), "解锁键缺修饰键")
    XCTAssertFalse(matches(unlock.keyCode, [.maskCommand]), "修饰键不全")
    XCTAssertTrue(matches(unlock.keyCode, flags))
    // Caps Lock 不算修饰键。
    XCTAssertTrue(matches(unlock.keyCode, flags.union(.maskAlphaShift)))
  }

  /// tap 回调在 tap 线程上跑。回调要是继承了主线程隔离,这里会直接 SIGTRAP。
  func testTapHandlerRunsOffMainThreadAndSwallowsEverything() async throws {
    let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    let swallowed = await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        let results = [CGEventType.keyDown, .keyUp, .flagsChanged].map {
          ScreenCleanController.handleTapEvent(type: $0, event: key) == nil
        }
        continuation.resume(returning: results)
      }
    }
    XCTAssertEqual(swallowed, [true, true, true])
  }

  /// 端到端:真起 HID tap + 黑窗,发合成按键。跑的时候屏幕会黑约 1 秒、期间吞掉键盘,
  /// 所以默认跳过,要跑时设 `VELTO_LIVE_TESTS=1`。
  func testLiveSessionEndsOnUnlockShortcut() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VELTO_LIVE_TESTS"] == "1", "会黑屏,默认不跑")
    let cleaner = ScreenCleanController.shared
    let unlock = ConfigStore.shared.preferences.macAssistant.screenCleanUnlockShortcut
    cleaner.setActive(true)
    defer {
      cleaner.setActive(false)
      resetModifierState()
    }
    try XCTSkipUnless(cleaner.isActive, "建不了 HID tap(缺辅助功能权限)")

    post(keyCode: 0, flags: [])  // A
    post(keyCode: unlock.keyCode, flags: [])  // 解锁键缺修饰键
    post(keyCode: unlock.keyCode, flags: [.maskCommand])  // 修饰键不全
    spin(0.3)
    XCTAssertTrue(cleaner.isActive, "非解锁键不该解锁")

    post(keyCode: unlock.keyCode, flags: CGEventFlags(rawValue: unlock.modifierFlags))
    spin(0.3)
    XCTAssertFalse(cleaner.isActive, "解锁键没解锁")
  }

  private func post(keyCode: UInt16, flags: CGEventFlags) {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
      event.flags = flags
      event.post(tap: .cghidEventTap)
    }
  }

  /// 发到 HID 的事件带修饰键时,系统的修饰键状态会一直留着,直到下一个 HID 事件。
  /// 之后新建的 CGEvent 全都继承它。光标原地发一个不带标志的移动,不打扰任何 App。
  private func resetModifierState() {
    let here = CGEvent(source: nil)?.location ?? .zero
    let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left)
    move?.flags = []
    move?.post(tap: .cghidEventTap)
  }

  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }
}
