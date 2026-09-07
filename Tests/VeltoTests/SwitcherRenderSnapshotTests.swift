import XCTest
import Cocoa
@testable import Velto

/// 不是断言测试 —— 把 tiles 面板真渲染成 PNG,人眼看一下高亮位置 / badge 大小 /
/// 缩放布局。跑完图在 scratchpad,失败也不会红。
@MainActor
final class SwitcherRenderSnapshotTests: XCTestCase {

  func testRenderPanelSnapshot() throws {
    guard let outDir = ProcessInfo.processInfo.environment["VELTO_SNAPSHOT_DIR"] else {
      throw XCTSkip("没给 VELTO_SNAPSHOT_DIR,跳过")
    }
    // 拿 Finder 当夹具 —— 它一定在跑,而且有真图标 / 真 localizedName,
    // 用 xctest 自己的话图标和 app 名都是空的,渲出来一片白看不出东西。
    let running = NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.apple.finder").first
      ?? NSRunningApplication.current
    let app = SwitcherApp(running)
    let titles = ["项目笔记.md", "Velto — main", "终端", "Slack #general", "预览"]
    let windows = titles.enumerated().map { idx, t in
      SwitcherWindow(
        application: app, cgWindowId: CGWindowID(idx + 1),
        axUiElement: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
        title: t, isMinimized: false, isFullscreen: false,
        spaceIds: [], position: nil, size: nil
      )
    }
    // 前 3 个塞假缩略图 —— 看 badge 角标大小;后 2 个留空 → 看大图标 fallback。
    for (idx, w) in windows.enumerated() where idx < 3 {
      w.setThumbnail(.cgImage(Self.solidImage(hue: CGFloat(idx) / 3)))
    }

    let maxSize = NSSize(width: 900, height: 800)
    let tiles = SwitcherTilesView(frame: NSRect(origin: .zero, size: maxSize))
    let size = tiles.rebuild(with: windows, maxSize: maxSize)
    tiles.frame = NSRect(origin: .zero, size: size)
    tiles.setSelectedIndex(1)
    tiles.setHoveredIndex(3)

    let window = NSWindow(
      contentRect: tiles.frame, styleMask: [.borderless],
      backing: .buffered, defer: false
    )
    window.contentView = tiles
    window.backgroundColor = .windowBackgroundColor
    window.orderBack(nil)
    tiles.displayIfNeeded()
    CATransaction.flush()

    let rep = try XCTUnwrap(tiles.bitmapImageRepForCachingDisplay(in: tiles.bounds))
    tiles.cacheDisplay(in: tiles.bounds, to: rep)
    // cacheDisplay 不画手动挂的 CALayer(选中高亮),补一遍 layer 渲染
    if let ctx = NSGraphicsContext(bitmapImageRep: rep), let root = tiles.layer {
      root.render(in: ctx.cgContext)
    }
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("switcher-panel.png")
    try png.write(to: url)
    print("SNAPSHOT → \(url.path)  size=\(size)")
    window.orderOut(nil)
  }

  /// 造一张纯色图当假缩略图。
  private static func solidImage(hue: CGFloat) -> CGImage? {
    let w = 320, h = 200
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let c = NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1)
    ctx.setFillColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // 加几道横线,一眼能看出图有没有被 badge 糊住
    ctx.setFillColor(gray: 1, alpha: 0.6)
    for i in 0..<5 {
      ctx.fill(CGRect(x: 20, y: 30 + i * 34, width: w - 40, height: 12))
    }
    return ctx.makeImage()
  }
}
