import ApplicationServices
import Testing

@testable import Velto

@Suite("AX 入口")
struct AXClientTests {
  @Test("AXValue 解码按类型来,类型不对返回 nil")
  func decodesAXValues() throws {
    var point = CGPoint(x: 12, y: 34)
    var size = CGSize(width: 56, height: 78)
    let pointValue = try #require(AXValueCreate(.cgPoint, &point))
    let sizeValue = try #require(AXValueCreate(.cgSize, &size))

    #expect(AXClient.point(from: pointValue) == point)
    #expect(AXClient.size(from: sizeValue) == size)
    #expect(AXClient.point(from: sizeValue) == nil)
    #expect(AXClient.size(from: pointValue) == nil)
    #expect(AXClient.point(from: "不是 AXValue" as CFString) == nil)
  }

  @Test("pid 只读 element 自带的信息")
  func readsPidFromElement() {
    #expect(AXClient.pid(of: AXClient.application(pid: 1234)) == 1234)
  }

  @Test("WindowHandle 和目标类型:只有 AX 句柄才算 AX 窗口")
  func targetExposesOnlyAccessibilityWindow() {
    let window = AXClient.application(pid: 1234)
    func target(_ handle: WindowHandle?) -> GestureExecutionTarget {
      GestureExecutionTarget(
        policy: .windowUnderPointer, pid: 1234, restoresOriginalFrontmostApplication: false,
        deliveryDelay: 0, handle: handle, prefersDirectWindowClose: false
      )
    }
    #expect(target(.accessibility(window)).window != nil)
    #expect(target(.windowServer(42)).window == nil)
    #expect(target(nil).window == nil)
  }
}
