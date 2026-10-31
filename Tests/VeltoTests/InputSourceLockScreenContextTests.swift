import XCTest

@testable import Velto

/// 锁屏 / 解锁授权界面必须被输入法自动切换忽略 —— 在那里切会把「会话待恢复的输入法」
/// 写成英文,解锁后系统恢复它,正好盖掉刚给前台 App 切好的 CJKV 输入法。
@MainActor
final class InputSourceLockScreenContextTests: XCTestCase {
  func testLockScreenBundleIDsAreIgnored() {
    for id in [
      "com.apple.loginwindow",
      "com.apple.SecurityAgent",
      "com.apple.SecurityAgentHelper.arm64",
      "com.apple.SecurityAgentHelper.x86_64",
      "com.apple.ScreenSaver.Engine",
      "com.apple.screensaver",
    ] {
      XCTAssertTrue(
        InputSourceSwitchController.isSystemAuthenticationContext(id), "应被忽略: \(id)")
    }
  }

  func testRegularAppsAreNotIgnored() {
    for id in [
      "com.tencent.xinWeChat",
      "ru.keepcoder.Telegram",
      "com.google.Chrome",
      "com.apple.Safari",
      "com.apple.finder",
    ] {
      XCTAssertFalse(
        InputSourceSwitchController.isSystemAuthenticationContext(id), "不该被忽略: \(id)")
    }
  }
}
