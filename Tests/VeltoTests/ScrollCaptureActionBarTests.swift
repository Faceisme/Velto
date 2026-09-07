import CoreGraphics
import Foundation
import Testing
import VeltoAnnotationCore

@Test func scrollActionBarUsesRightLowerSideWhenThereIsRoom() {
  let frame = ScrollCaptureActionBarLayout.place(
    selection: CGRect(x: 100, y: 120, width: 100, height: 100),
    screenBounds: CGRect(x: 0, y: 0, width: 400, height: 400),
    barSize: CGSize(width: 56, height: 168),
    gap: 8
  )

  #expect(frame == CGRect(x: 208, y: 120, width: 56, height: 168))
}

@Test func scrollActionBarFlipsLeftWhenRightSideIsSqueezed() {
  let frame = ScrollCaptureActionBarLayout.place(
    selection: CGRect(x: 280, y: 120, width: 100, height: 100),
    screenBounds: CGRect(x: 0, y: 0, width: 400, height: 400),
    barSize: CGSize(width: 56, height: 168),
    gap: 8
  )

  #expect(frame == CGRect(x: 216, y: 120, width: 56, height: 168))
}

@Test func scrollActionBarFallsBackInsideSelectionWhenOutsideIsFull() {
  let frame = ScrollCaptureActionBarLayout.place(
    selection: CGRect(x: 60, y: 20, width: 240, height: 140),
    screenBounds: CGRect(x: 0, y: 0, width: 360, height: 180),
    barSize: CGSize(width: 56, height: 168),
    gap: 8
  )

  #expect(frame == CGRect(x: 304, y: 12, width: 56, height: 168))
}

@Test func scrollActionBarProvidesBorderActions() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let barURL = root.appendingPathComponent("Sources/Velto/Screenshot/ScrollCaptureActionBar.swift")
  let sessionURL = root.appendingPathComponent("Sources/Velto/Screenshot/ScreenshotSession.swift")
  let bar = try String(contentsOf: barURL, encoding: .utf8)
  let session = try String(contentsOf: sessionURL, encoding: .utf8)

  for title in ["完成", "复制", "存储到本地", "取消"] {
    #expect(bar.contains("\"\(title)\""))
  }
  #expect(bar.contains("AnnotationToolbarButton"))
  #expect(bar.contains("makeButton(icon: .complete"))
  #expect(bar.contains("makeButton(icon: .copy"))
  #expect(bar.contains("makeButton(icon: .save"))
  #expect(bar.contains("makeButton(icon: .cancel"))
  #expect(bar.contains("content.orientation = .vertical"))
  #expect(!bar.contains("content.orientation = .horizontal"))
  #expect(!bar.contains("NSButton"))
  #expect(!bar.contains("ScrollCaptureActionButton"))
  #expect(bar.contains("ScrollCaptureActionBarLayout.place"))
  #expect(session.contains("scrollActionBar"))
  #expect(session.contains("ScrollCaptureActionBar"))
  #expect(session.contains("onFinish"))
  #expect(session.contains("onCopy"))
  #expect(session.contains("onSave"))
  #expect(session.contains("onCancel"))
}
