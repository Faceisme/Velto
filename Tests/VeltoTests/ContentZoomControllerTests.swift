import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import Velto

private final class RecordedSteps: Sendable {
  private let values = Mutex<[Bool]>([])

  var all: [Bool] { values.withLock { $0 } }

  func append(_ zoomIn: Bool) {
    values.withLock { $0.append(zoomIn) }
  }
}

@Suite("内容缩放")
struct ContentZoomControllerTests {
  private let modifier = UInt64(CGEventFlags.maskControl.rawValue)

  private func wheel(_ delta: Int32) throws -> CGEvent {
    let event = try #require(CGEvent(
      scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
    event.flags = []
    return event
  }

  private func controller(recording steps: RecordedSteps) -> ContentZoomController {
    let controller = ContentZoomController()
    controller.stepSender = { steps.append($0) }
    controller.updateModifierFlag(modifier)
    return controller
  }

  private func waitFor(_ count: Int, in steps: RecordedSteps) async throws -> [Bool] {
    for _ in 0..<100 where steps.all.count < count {
      try await Task.sleep(for: .milliseconds(20))
    }
    return steps.all
  }

  @Test("修饰键不对时不接管滚轮")
  func ignoresOtherModifiers() throws {
    let steps = RecordedSteps()
    let controller = controller(recording: steps)
    #expect(!controller.handleScrollWheel(event: try wheel(1), normalizedFlags: 0))
    #expect(!controller.handleScrollWheel(
      event: try wheel(1), normalizedFlags: UInt64(CGEventFlags.maskCommand.rawValue)))
  }

  @Test("没配修饰键时不接管")
  func unconfiguredModifierNeverMatches() throws {
    let controller = ContentZoomController()
    #expect(!controller.handleScrollWheel(event: try wheel(1), normalizedFlags: 0))
    #expect(!controller.modifierMatches(rawValue: 0))
  }

  @Test("按着修饰键时吞掉没有位移的滚轮帧")
  func swallowsEmptyWheelFrames() throws {
    let steps = RecordedSteps()
    let controller = controller(recording: steps)
    #expect(controller.handleScrollWheel(event: try wheel(0), normalizedFlags: modifier))
  }

  @Test("正向放大,反向缩小")
  func wheelDirectionMapsToZoom() async throws {
    let up = RecordedSteps()
    let zoomIn = controller(recording: up)
    defer { withExtendedLifetime(zoomIn) {} }
    #expect(zoomIn.handleScrollWheel(event: try wheel(1), normalizedFlags: modifier))
    #expect(try await waitFor(1, in: up) == [true])

    let down = RecordedSteps()
    let zoomOut = controller(recording: down)
    defer { withExtendedLifetime(zoomOut) {} }
    #expect(zoomOut.handleScrollWheel(event: try wheel(-1), normalizedFlags: modifier))
    #expect(try await waitFor(1, in: down) == [false])
  }

  @Test("一次滚动最多积压 4 步")
  func capsBufferedSteps() async throws {
    let steps = RecordedSteps()
    let controller = controller(recording: steps)
    defer { withExtendedLifetime(controller) {} }
    #expect(controller.handleScrollWheel(event: try wheel(10), normalizedFlags: modifier))

    #expect(try await waitFor(4, in: steps) == [true, true, true, true])
    try await Task.sleep(for: .milliseconds(150))
    #expect(steps.all.count == 4)
  }

  @Test("松开修饰键后不再发出积压的步")
  func releasingModifierDropsBufferedSteps() async throws {
    let steps = RecordedSteps()
    let controller = controller(recording: steps)
    defer { withExtendedLifetime(controller) {} }
    #expect(controller.handleScrollWheel(event: try wheel(4), normalizedFlags: modifier))
    _ = try await waitFor(1, in: steps)

    controller.handleFlagsChanged(normalizedFlags: 0)
    let afterRelease = steps.all.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(steps.all.count <= afterRelease + 1)
  }
}
