import CoreGraphics
import Testing

@testable import Velto

private let screen = CGRect(x: 0, y: 0, width: 2048, height: 1152)

/// 只在挡住的那条边附近改坐标,别处原样放行。
@Test func dockRevealGuardClampsOnlyTheDockEdge() {
  let bottom = DockRevealGuard.Region(displayBounds: screen, edge: .bottom)
  #expect(DockRevealGuard.clamped(CGPoint(x: 900, y: 1151.9), region: bottom) == CGPoint(x: 900, y: 1149))
  #expect(DockRevealGuard.clamped(CGPoint(x: 900, y: 1152), region: bottom) == CGPoint(x: 900, y: 1149))
  #expect(DockRevealGuard.clamped(CGPoint(x: 900, y: 1100), region: bottom) == CGPoint(x: 900, y: 1100))
  // 左右边、顶边不受影响(全屏时顶部还要能叫出菜单栏)。
  #expect(DockRevealGuard.clamped(CGPoint(x: 0, y: 500), region: bottom) == CGPoint(x: 0, y: 500))
  #expect(DockRevealGuard.clamped(CGPoint(x: 900, y: 0), region: bottom) == CGPoint(x: 900, y: 0))
  // 别的屏幕上的点不管。
  #expect(DockRevealGuard.clamped(CGPoint(x: 3000, y: 1151), region: bottom) == CGPoint(x: 3000, y: 1151))

  let left = DockRevealGuard.Region(displayBounds: screen, edge: .left)
  #expect(DockRevealGuard.clamped(CGPoint(x: 0.5, y: 500), region: left) == CGPoint(x: 3, y: 500))
  let right = DockRevealGuard.Region(displayBounds: screen, edge: .right)
  #expect(DockRevealGuard.clamped(CGPoint(x: 2048, y: 500), region: right) == CGPoint(x: 2045, y: 500))
}

/// 程序坞那条边外面紧挨着别的屏幕时不挡,否则指针过不去。
@Test func dockRevealGuardSkipsEdgesSharedWithAnotherDisplay() {
  let below = CGRect(x: 0, y: 1152, width: 1920, height: 1080)
  let beside = CGRect(x: 2048, y: 0, width: 1920, height: 1080)
  #expect(DockRevealGuard.edgeIsOuter(.bottom, of: screen, among: [screen]))
  #expect(!DockRevealGuard.edgeIsOuter(.bottom, of: screen, among: [screen, below]))
  #expect(DockRevealGuard.edgeIsOuter(.bottom, of: screen, among: [screen, beside]))
  #expect(!DockRevealGuard.edgeIsOuter(.right, of: screen, among: [screen, beside]))
}
