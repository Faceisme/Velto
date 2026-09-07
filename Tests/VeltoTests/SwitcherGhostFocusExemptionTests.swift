import CoreGraphics
import Foundation
import Testing

@testable import Velto

/// `SwitcherGhostDetector.isInvisible` 的 isFocused 豁免(移植自 alt-tab #5849)。
///
/// 场景:Electron app(Slack / Telegram)从 Dock 唤回后,窗口已经在屏并且是聚焦的,
/// CGS 却还会继续给它打 invisible 标记好几秒 —— 正好是用户点完 Dock 想 ⌥Tab 回去
/// 的那几秒,窗口被判成 ghost 从清单里消失。
///
/// 真正要钉住的是**豁免的位置**:它排在"CGS 完全不认这个 wid"这条最强信号之后。
/// 聚焦态只能推翻末尾那条弱信号,推翻强信号就会把 `show:false` 的隐藏窗口放回来。
private let wid: CGWindowID = 42

private func verdict(
  isFocused: Bool,
  inAll: Bool = true,
  inVisible: Bool = false,
  isMinimized: Bool = false,
  spaceIds: [CGSSpaceID] = []
) -> Bool {
  SwitcherGhostDetector.isInvisible(
    wid: wid,
    isMinimized: isMinimized,
    isAppHidden: false,
    isTabbed: false,
    isFocused: isFocused,
    windowSpaceIds: spaceIds,
    visibleSpaceIds: [1],
    probe: WindowVisibilityProbe(
      visibleWids: inVisible ? [wid] : [],
      allWids: inAll ? [wid] : []
    )
  )
}

@Test("弱信号:CGS 认识但不在 visible 桶、也没有 Space 归属 → ghost")
func weakSignalIsGhostWhenNotFocused() {
  #expect(verdict(isFocused: false) == true)
}

@Test("同样的弱信号,窗口正被聚焦 → 豁免(Electron 从 Dock 唤回的那几秒)")
func focusedWindowSurvivesWeakSignal() {
  #expect(verdict(isFocused: true) == false)
}

@Test("强信号不可推翻:CGS 完全不认这个 wid,聚焦也照样判 ghost")
func focusedDoesNotOverrideStrongSignal() {
  #expect(verdict(isFocused: true, inAll: false) == true)
}

@Test("在 visible 桶里本来就不是 ghost,isFocused 不改变结论")
func visibleBucketUnaffectedByFocus() {
  #expect(verdict(isFocused: false, inVisible: true) == false)
  #expect(verdict(isFocused: true, inVisible: true) == false)
}

@Test("最小化 / 跨 Space 这些合法理由排在豁免之前,结论不受 isFocused 影响")
func legitimateInvisibilityUnaffectedByFocus() {
  #expect(verdict(isFocused: false, isMinimized: true) == false)
  #expect(verdict(isFocused: true, isMinimized: true) == false)
  // 有 Space 归属但都不在当前可见 Space(visibleSpaceIds = [1])
  #expect(verdict(isFocused: false, spaceIds: [7]) == false)
}
