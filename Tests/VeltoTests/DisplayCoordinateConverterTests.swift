import CoreGraphics
import Testing

@testable import Velto

/// 多显示器的换算。开发机是单屏,这些排布只能靠单元测试守住。
@Suite("全局坐标换算")
struct DisplayCoordinateConverterTests {
  private typealias Converter = DisplayCoordinateConverter

  private let primaryHeight: CGFloat = 1080
  private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  /// 菜单栏 30,程序坞 54。
  private func screen(_ frame: CGRect) -> Converter.ScreenFrames {
    Converter.ScreenFrames(
      frame: frame,
      visibleFrame: CGRect(x: frame.minX, y: frame.minY + 54, width: frame.width, height: frame.height - 84)
    )
  }

  private func overlayPoint(_ point: CGPoint, desktop: CGRect) -> CGPoint {
    Converter.overlayPoint(fromEventLocation: point, desktopFrame: desktop, primaryHeight: primaryHeight)
  }

  @Test("翻转两次回到原值")
  func flipIsItsOwnInverse() {
    let rect = CGRect(x: -500, y: 1100, width: 300, height: 200)
    let point = CGPoint(x: -40, y: 1500)
    #expect(Converter.flipped(Converter.flipped(rect, primaryHeight: primaryHeight), primaryHeight: primaryHeight) == rect)
    #expect(Converter.flipped(Converter.flipped(point, primaryHeight: primaryHeight), primaryHeight: primaryHeight) == point)
  }

  @Test("翻转轴是主屏高度,矩形按上边算")
  func flippedRectUsesPrimaryHeight() {
    let appKit = CGRect(x: 100, y: 200, width: 300, height: 400)
    #expect(Converter.flipped(appKit, primaryHeight: primaryHeight) == CGRect(x: 100, y: 480, width: 300, height: 400))
  }

  @Test("单屏:轨迹坐标就是 y 翻转")
  func overlayPointOnSingleDisplay() {
    #expect(overlayPoint(CGPoint(x: 100, y: 200), desktop: primary) == CGPoint(x: 100, y: 880))
  }

  @Test("副屏在主屏左边:轨迹 x 要减去桌面左边界")
  func overlayPointWithDisplayOnTheLeft() {
    let desktop = primary.union(CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    #expect(overlayPoint(CGPoint(x: -100, y: 500), desktop: desktop) == CGPoint(x: 1820, y: 580))
    #expect(overlayPoint(CGPoint(x: 100, y: 500), desktop: desktop) == CGPoint(x: 2020, y: 580))
  }

  @Test("副屏在主屏上方:翻转轴仍是主屏高度")
  func overlayPointWithDisplayAbove() {
    let desktop = primary.union(CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    // Quartz y = -500 在副屏上,AppKit y = 1580。
    #expect(overlayPoint(CGPoint(x: 100, y: -500), desktop: desktop) == CGPoint(x: 100, y: 1580))
    #expect(overlayPoint(CGPoint(x: 100, y: 200), desktop: desktop) == CGPoint(x: 100, y: 880))
  }

  @Test("副屏在主屏下方:轨迹 y 要减去桌面下边界")
  func overlayPointWithDisplayBelow() {
    let desktop = primary.union(CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    // Quartz y = 1500 在副屏上,AppKit y = -420。
    #expect(overlayPoint(CGPoint(x: 100, y: 1500), desktop: desktop) == CGPoint(x: 100, y: 660))
    #expect(overlayPoint(CGPoint(x: 100, y: 200), desktop: desktop) == CGPoint(x: 100, y: 1960))
  }

  @Test("最大化选屏:按光标所在屏幕,返回 Quartz 坐标")
  func visibleFrameFollowsPointer() {
    let left = screen(CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    let main = screen(primary)
    let frame = Converter.visibleFrame(
      containing: CGPoint(x: -100, y: 500), screens: [main, left], primaryHeight: primaryHeight
    )
    #expect(frame == CGRect(x: -1920, y: 30, width: 1920, height: 996))
  }

  @Test("最大化选屏:副屏在主屏上方")
  func visibleFrameOnDisplayAbove() {
    let above = screen(CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    let frame = Converter.visibleFrame(
      containing: CGPoint(x: 100, y: -500), screens: [screen(primary), above], primaryHeight: primaryHeight
    )
    #expect(frame == CGRect(x: 0, y: -1050, width: 1920, height: 996))
  }

  @Test("光标在菜单栏上也算这块屏幕")
  func visibleFrameFromMenuBar() {
    let left = screen(CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    let frame = Converter.visibleFrame(
      containing: CGPoint(x: -100, y: 5), screens: [screen(primary), left], primaryHeight: primaryHeight
    )
    #expect(frame == CGRect(x: -1920, y: 30, width: 1920, height: 996))
  }

  @Test("点不在任何屏幕上时用主屏,没有屏幕时返回空")
  func visibleFrameFallbacks() {
    let main = screen(primary)
    #expect(
      Converter.visibleFrame(containing: CGPoint(x: 9000, y: 9000), screens: [main], primaryHeight: primaryHeight)
        == CGRect(x: 0, y: 30, width: 1920, height: 996)
    )
    #expect(Converter.visibleFrame(containing: .zero, screens: [], primaryHeight: 0) == .zero)
  }
}
