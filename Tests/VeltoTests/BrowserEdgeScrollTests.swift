import CoreGraphics
import Testing

@testable import Velto

@Suite("浏览器置顶/置底滚轮补发")
struct BrowserEdgeScrollTests {
  private func shortcut(_ keyCode: UInt16, _ flags: UInt64) -> Shortcut {
    Shortcut(keyCode: keyCode, modifierFlags: flags, displayName: "")
  }

  private let up = VirtualKeyCode.upArrow
  private let down = VirtualKeyCode.downArrow

  /// 0x900000 是手势里实际存的值(⌘ + 方向键天然带的 Fn),0xB00000 是硬件事件的样子。
  @Test("⌘↑ / ⌘↓ 不管带不带 Fn、小键盘位都算", arguments: [UInt64(0x100000), 0x900000, 0xB00000])
  func commandArrowIsEdge(flags: UInt64) {
    #expect(BrowserEdgeScroll.edge(for: shortcut(up, flags)) == .top)
    #expect(BrowserEdgeScroll.edge(for: shortcut(down, flags)) == .bottom)
  }

  /// 0x880000 是 Movist 手势用的 ⌥Fn↑,其余是带了别的修饰键的组合,含义都不是滚到边。
  @Test("多带或换了修饰键不算", arguments: [UInt64(0), 0x880000, 0x120000, 0x140000, 0x180000])
  func otherModifiersAreNotEdge(flags: UInt64) {
    #expect(BrowserEdgeScroll.edge(for: shortcut(up, flags)) == nil)
    #expect(BrowserEdgeScroll.edge(for: shortcut(down, flags)) == nil)
  }

  @Test("其他键不算")
  func otherKeysAreNotEdge() {
    #expect(BrowserEdgeScroll.edge(for: shortcut(123, 0x900000)) == nil)
    #expect(BrowserEdgeScroll.edge(for: shortcut(124, 0x900000)) == nil)
    #expect(BrowserEdgeScroll.edge(for: shortcut(VirtualKeyCode.w, 0x100000)) == nil)
  }

  @Test("到顶往上滚,到底往下滚")
  func wheelDirection() {
    #expect(BrowserEdgeScroll.wheelDelta(for: .top) > 0)
    #expect(BrowserEdgeScroll.wheelDelta(for: .bottom) < 0)
  }

  /// 带了别处的坐标,post 到 session tap 时会把系统光标带过去(手势松手后光标跳回起点)。
  @Test("滚轮事件留在光标当前位置")
  func wheelEventStaysAtCursor() throws {
    let event = try #require(BrowserEdgeScroll.makeWheelEvent(for: .top))
    let cursor = try #require(CGEvent(source: nil)).location
    #expect(event.location == cursor)
  }

  @Test("滚轮事件带合成标记,不被鼠标控制再处理一遍")
  func wheelEventCarriesSyntheticMarker() throws {
    let event = try #require(BrowserEdgeScroll.makeWheelEvent(for: .bottom))
    #expect(event.getIntegerValueField(.eventSourceUserData) == MouseControlController.syntheticScrollMarker)
  }

  @Test("拿不到 App 时不补滚轮")
  func unknownApplicationIsNotBrowser() {
    #expect(!BrowserEdgeScroll.isBrowser(nil))
  }
}
