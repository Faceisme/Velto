import AppKit
import Testing
@testable import Velto

/// 真机录屏:常驻流的帧必须和逐帧截图同尺寸、同像素(±1),否则底边扩展混用两种来源会接不上。
@MainActor
@Suite(.enabled(if: CGPreflightScreenCaptureAccess()), .serialized)
struct RegionFrameStreamTests {
  private func mainSnapshot() async throws -> DisplaySnapshot {
    try #require(try await ScreenshotCapturer.captureAllDisplays().first { $0.displayID == CGMainDisplayID() })
  }

  private func pixels(_ image: CGImage) -> [UInt8] {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                     count: image.width * image.height * 4))
  }

  @Test func streamFrameMatchesScreenshot() async throws {
    let snapshot = try await mainSnapshot()
    let rect = CGRect(x: snapshot.frame.minX + 40, y: snapshot.frame.minY + 300, width: 301, height: 203)
    let stream = try #require(await RegionFrameStream.start(in: snapshot, globalRect: rect))
    defer { stream.stop() }
    #expect(stream.sequence > 0)
    let streamed = try #require(stream.latestImage())
    let shot = try #require(try await ScreenshotCapturer.captureRegion(in: snapshot, globalRect: rect))
    #expect(streamed.width == shot.width && streamed.height == shot.height)
    let a = pixels(streamed), b = pixels(shot)
    let differing = zip(a, b).filter { abs(Int($0) - Int($1)) > 1 }.count
    // 两次抓之间屏幕可能有小变化,只要求绝大多数像素一致。
    #expect(differing * 20 < a.count, "differing=\(differing)/\(a.count)")
    stream.stop()
    #expect(stream.latestImage() == nil)
  }

  @Test func controllerRunsOnStream() async throws {
    let snapshot = try await mainSnapshot()
    let rect = CGRect(x: snapshot.frame.minX + 40, y: snapshot.frame.minY + 300, width: 301, height: 203)
    let controller = ScrollCaptureController(snapshot: snapshot, captureRect: rect)
    #expect(await controller.startSession())
    try await Task.sleep(for: .milliseconds(400))
    let result = try #require(await controller.finishSession())
    #expect(result.width == Int(rect.width * snapshot.scale))
  }
}
