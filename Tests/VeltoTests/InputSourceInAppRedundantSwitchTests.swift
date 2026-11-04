import CoreGraphics
import XCTest

@testable import Velto

/// 回归(2026-11-04):Chrome 窗口靠右时新建标签页明显卡顿。新标签页聚焦地址栏 →
/// 上下文从「网页」换成「地址栏」→ 原来无条件 TISSelectInputSource(US),哪怕已经是 US →
/// macOS 在地址栏光标旁弹输入法指示气泡(Chrome 进程里的新窗口,AXDialog 84×77)→
/// 切换器收到 kAXWindowCreated 对 Chrome 整轮暴力枚举。光标在屏幕外时气泡不弹,
/// 所以只有窗口靠右才卡。停掉 Velto 气泡就不出现。
@MainActor
final class InputSourceInAppRedundantSwitchTests: XCTestCase {
  private let us = "com.apple.keylayout.US"
  private let doubao = "com.bytedance.inputmethod.doubaoime.pinyin::com.bytedance.inputmethod.doubaoime.pinyin"

  private func redundant(
    previous: String? = "com.google.Chrome",
    bundle: String = "com.google.Chrome",
    current: String?,
    target: String,
    pending: Bool = false
  ) -> Bool {
    InputSourceSwitchController.isRedundantInAppSwitch(
      previousBundleID: previous, bundleID: bundle, currentID: current, targetID: target,
      hasPendingSwitch: pending)
  }

  /// 网页 → 地址栏(新建标签页)、地址栏 → 网页(关标签页),当前已是 US:不再切。
  func testSameBrowserAlreadyOnTargetSkips() {
    XCTAssertTrue(redundant(current: us, target: us))
  }

  /// 进入别的 App 仍然无条件切一次(对齐 ISP,防 IME 在激活后把输入法顶回去)。
  func testEnteringAnotherAppStillSwitches() {
    XCTAssertFalse(redundant(previous: "com.tencent.xinWeChat", current: us, target: us))
  }

  /// 刚启动或锁屏后 lastContext 被清空:按进入新上下文处理,照常切。
  func testNoPreviousContextStillSwitches() {
    XCTAssertFalse(redundant(previous: nil, current: us, target: us))
  }

  /// 同一个浏览器里目标变了(比如网站规则要豆包),照常切。
  func testSameBrowserDifferentTargetSwitches() {
    XCTAssertFalse(redundant(current: us, target: doubao))
    XCTAssertFalse(redundant(current: doubao, target: us))
  }

  /// CJKV 修复的 bounce 中途、落地校验没到点:当前读数不可信,照常切。
  func testPendingSwitchSequenceStillSwitches() {
    XCTAssertFalse(redundant(current: us, target: us, pending: true))
  }

  /// 读不到当前输入法:不能断定已在目标上,照常切。
  func testUnknownCurrentStillSwitches() {
    XCTAssertFalse(redundant(current: nil, target: us))
  }

  /// 输入法指示气泡、工具提示不够窗口个头,切换器收到它们的 kAXWindowCreated 不再整轮扫描。
  func testInputSourceIndicatorIsNotWindowSized() {
    XCTAssertFalse(SwitcherWindowDiscriminator.isWindowSized(CGSize(width: 84, height: 77)))
    XCTAssertFalse(SwitcherWindowDiscriminator.isWindowSized(CGSize(width: 54, height: 54)))
    XCTAssertFalse(SwitcherWindowDiscriminator.isWindowSized(CGSize(width: 215, height: 22)))
    XCTAssertTrue(SwitcherWindowDiscriminator.isWindowSized(CGSize(width: 101, height: 51)))
    XCTAssertTrue(SwitcherWindowDiscriminator.isWindowSized(CGSize(width: 1920, height: 996)))
    XCTAssertFalse(
      SwitcherWindowDiscriminator.isActualWindow(
        bundleIdentifier: "com.google.Chrome", wid: 10014, title: nil,
        subrole: "AXDialog", role: "AXWindow", size: CGSize(width: 84, height: 77)))
  }
}
