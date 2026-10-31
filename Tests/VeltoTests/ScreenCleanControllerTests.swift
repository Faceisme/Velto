import AppKit
import XCTest
@testable import Velto

/// 擦屏助手端到端:真起 HID tap + 黑窗,发合成按键。跑的时候会黑屏约 1 秒、期间吞掉键盘。
@MainActor
final class ScreenCleanControllerTests: XCTestCase {
  func testOnlyUnlockShortcutEndsSession() throws {
    let cleaner = ScreenCleanController.shared
    let unlock = GestureStore.shared.preferences.macAssistant.screenCleanUnlockShortcut
    cleaner.setActive(true)
    defer { cleaner.setActive(false) }
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

  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }
}
