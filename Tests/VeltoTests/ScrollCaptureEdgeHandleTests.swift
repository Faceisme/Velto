import CoreGraphics
import Foundation
import Testing
@testable import Velto

@Test @MainActor func edgeHandleStraddlesSelectionBottomCenter() {
  let selection = CGRect(x: 100, y: 200, width: 400, height: 300)
  let frame = ScrollCaptureEdgeHandle.frame(for: selection)

  #expect(frame.midX == selection.midX)
  #expect(frame.midY == selection.minY)
  #expect(frame.size == ScrollCaptureEdgeHandle.handleSize)
}

/// 会话/控制器接线回归:底边扩展的关键路径存在且清理完整。
@Test func scrollCaptureExtendBottomIsWired() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let session = try String(
    contentsOf: root.appendingPathComponent("Sources/Velto/Screenshot/ScreenshotSession.swift"),
    encoding: .utf8)
  let controller = try String(
    contentsOf: root.appendingPathComponent("Sources/Velto/Screenshot/ScrollCaptureController.swift"),
    encoding: .utf8)

  // 控制器:扩大选区只抓同一帧,保留其完整基准,避免扩展后的短滚动丢失。
  #expect(controller.contains("func extendBottom(byPoints"))
  #expect(controller.contains("captureSettledFrame(rect: expandedRect)"))
  #expect(controller.contains("shotA = expanded"))
  #expect(!controller.contains("shotA = nil"))

  // 会话:创建手柄、预览走边框更新、提交走控制器、teardown 收回手柄。
  #expect(session.contains("ScrollCaptureEdgeHandle(selectionRect:"))
  #expect(session.contains("commitScrollRegionExtension(byPoints"))
  #expect(session.contains("controller.extendBottom(byPoints: delta)"))
  #expect(session.contains("scrollEdgeHandle?.orderOut(nil)"))
}
