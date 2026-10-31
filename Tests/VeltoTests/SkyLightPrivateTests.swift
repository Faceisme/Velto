import ApplicationServices
import CoreGraphics
import Testing

@testable import Velto

/// 私有符号运行时查找:当前系统上都要找得到,找不到时不能崩。
@Suite("私有符号")
struct SkyLightPrivateTests {
  /// 系统更新移除符号时这条会先红,比等用户发现功能失效早。
  @Test("当前系统上全部符号都能找到")
  func allSymbolsResolve() {
    #expect(SkyLightPrivate.missingSymbols == [])
  }

  @Test("不存在的符号返回 nil")
  func unknownSymbolIsNil() {
    #expect(SkyLightPrivate.address(of: "VeltoNoSuchPrivateSymbol") == nil)
  }

  @Test("WindowServer 连接可用")
  func connection() {
    #expect(CGS_CONNECTION != 0)
    #expect(CGSMainConnectionID() == CGS_CONNECTION)
  }

  /// 反复调用确认返回值所有权写对了:过度释放会在这里崩。
  @Test("Copy 类函数的返回值可以反复取用")
  func copiedArraysStayValid() {
    for _ in 0..<200 {
      let spaces = CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as? [[String: Any]]
      #expect(spaces != nil)
      var setTags = 0
      var clearTags = 0
      let windows = CGSCopyWindowsWithOptionsAndTags(
        CGS_CONNECTION, 0, [] as CFArray, 0, &setTags, &clearTags)
      #expect(CFGetTypeID(windows) == CFArrayGetTypeID())
    }
  }

  @Test("能取到自己进程的 PSN")
  func processSerialNumber() {
    var psn = ProcessSerialNumber()
    #expect(GetProcessForPID(getpid(), &psn) == noErr)
    #expect(psn.highLongOfPSN != 0 || psn.lowLongOfPSN != 0)
  }

  @Test("非窗口元素取 wid 返回错误而不是崩溃")
  func windowLookupOnApplicationElement() {
    var wid: CGWindowID = 0
    #expect(_AXUIElementGetWindow(AXUIElementCreateApplication(getpid()), &wid) != .success)
  }

  @Test("坏 token 不会崩溃")
  func remoteTokenWithGarbage() {
    let token = Data(repeating: 0, count: 20) as CFData
    _ = _AXUIElementCreateWithRemoteToken(token)?.takeRetainedValue()
  }
}
