import Foundation
import Testing

@testable import Velto

/// AX 熔断与超时归属的回归测试。
///
/// 这些不变量都在 private static 里,没有可注入的接口,而真实行为要靠"存在一个
/// 对 AX 装哑巴的 app"才能触发(Telegram / 微信 / 富途)。所以这里退一步做源码
/// 结构断言 —— 与 `GestureFoldBucketBoundaryRegressionTests` 同思路:守住"别再改
/// 回去"这一条,而不是守住数值。
@Suite("AX 熔断")
struct AxCircuitBreakerTests {
  private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // VeltoTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // 仓库根
    let url = root.appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// 命中测试不能再每次调用都重设进程全局超时 —— 那会把切换器的预算一起改掉。
  @Test("命中测试只设一次进程全局超时")
  func globalTimeoutInstalledOnce() throws {
    let text = try source("Sources/Velto/GestureTargetController.swift")

    #expect(text.contains("installGlobalTimeout"))

    // elementAtPosition 函数体里不允许再出现 SetMessagingTimeout。
    let marker = "private static func elementAtPosition("
    let start = try #require(text.range(of: marker))
    let body = text[start.upperBound...].prefix(600)
    #expect(!body.contains("AXUIElementSetMessagingTimeout"))
  }

  /// 全局值必须由 AXCallQueue 与 GestureTargetController 共用同一个常量,
  /// 否则两边会互相覆盖(历史 bug:1.0s 被 0.1s 永久顶掉)。
  @Test("全局超时只有一个来源")
  func globalTimeoutHasSingleSource() throws {
    let gesture = try source("Sources/Velto/GestureTargetController.swift")
    let queue = try source("Sources/Velto/Switcher/AXCallQueue.swift")

    #expect(gesture.contains("AXCallQueue.processMessagingTimeout"))
    #expect(queue.contains("Self.processMessagingTimeout"))
    #expect(GestureTargetController.axMessagingTimeout == AXCallQueue.processMessagingTimeout)
  }

  /// 切换器需要更长预算,但只能设在自己的 app 元素上(元素级),不能再传 systemWide。
  @Test("切换器用元素级超时")
  func switcherUsesElementScopedTimeout() throws {
    let text = try source("Sources/Velto/Switcher/SwitcherApp.swift")

    #expect(text.contains("AXUIElementSetMessagingTimeout(axUiElement, AXCallQueue.appMessagingTimeout)"))
    #expect(!text.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide()"))
    #expect(AXCallQueue.appMessagingTimeout > AXCallQueue.processMessagingTimeout)
  }

  /// 熔断本体:查到空窗口要记一笔,后续命中测试与窗口枚举都要先问一句。
  @Test("AX 哑巴 app 会被熔断并跳过")
  func deadPidsAreSkipped() throws {
    let text = try source("Sources/Velto/GestureTargetController.swift")

    // 账本必须是共用的那份,不能各自再开一个 pid 表。
    #expect(text.contains("AxDeadPids.isDead(pid)"))
    #expect(!text.contains("Mutex<[pid_t: CFAbsoluteTime]>"))

    // kAXWindows 空 → 熔断,且必须报上来源(日志在账本里打,见下面那条测试)
    #expect(text.contains("AxDeadPids.mark(targetPid, source:"))
    // 本地不许再包一层打日志的 markAxDead —— 那正是切换器调用点当初能悄悄
    // 拉黑 Chrome 的原因(账本外的调用点想打就打、不想打就不打)。
    #expect(!text.contains("func markAxDead"))
    // 熔断后 axWindow 立刻返回,不再 AXUIElementCreateApplication
    let marker = "private static func axWindow(matching candidate:"
    let start = try #require(text.range(of: marker))
    let body = text[start.upperBound...].prefix(400)
    let guardIndex = try #require(body.range(of: "axIsDead(targetPid)"))
    let createIndex = try #require(body.range(of: "AXUIElementCreateApplication"))
    #expect(guardIndex.lowerBound < createIndex.lowerBound)

    // 命中测试路径同样要前置检查
    #expect(text.contains("axIsDead(topCandidate.pid)"))

    // 命中测试失败**不能**熔断:那可能只是偶发超时,误伤健康 app 的 ⌥ 拖拽。
    #expect(!text.contains("命中测试全部返回 nil\")"))
  }

  /// 切换器的暴力枚举也要查同一份账本 —— 启动时 `setMaintainsIndex(true)` 遍历
  /// 所有 app,9 个哑巴 app × 100ms ≈ 0.9s 全烧在它们各自的主线程上。
  @Test("切换器暴力枚举跳过熔断 pid")
  func bruteForceRespectsBreaker() throws {
    let text = try source("Sources/Velto/Switcher/SwitcherApp.swift")

    #expect(text.contains("includeBruteForce && !AxDeadPids.isDead(pid)"))
    // **两条 AX 路径同时空手**才熔断。少了 `stdWindows.isEmpty` 就会误伤临时忙的
    // 健康 app:2026-08-26 Chrome 26 次手势目标定位被这么废掉 9 次(一次连黑
    // 10.4s)。kAXWindows 都拿到窗口了根本不瞎,熔断纯亏。
    #expect(text.contains("if brute.timedOut, brute.windows.isEmpty, stdWindows.isEmpty {"))
    #expect(text.contains("AxDeadPids.mark("))
    #expect(text.contains("timedOut: Bool"))
    // 日志仍要带 stdWindows 数 —— 残余误伤(窗口全在别的 Space,标准路径也空)
    // 得靠它认出来。
    #expect(text.contains("标准路径 \\(stdWindows.count) 窗口"))
  }

  /// 账本本体的行为(TTL 到期恢复没测,那得真等 5 秒)。
  @Test("熔断账本:首次标记与重复标记可区分")
  func breakerMarksOnce() {
    let pid: pid_t = 0x7f_ff_ff  // 不会与真实进程撞车
    #expect(!AxDeadPids.isDead(pid))
    #expect(AxDeadPids.mark(pid, source: "test"))  // 首次 → true
    #expect(AxDeadPids.isDead(pid))
    #expect(!AxDeadPids.mark(pid, source: "test"))  // 已在黑名单 → false(续期)
    #expect(AxDeadPids.ttlSeconds > 0)
  }

  /// 日志必须打在账本里,而不是各调用点自愿打 —— 这是 2026-08-26 排查
  /// "Chrome 被谁熔断了"时唯一查不下去的地方。
  @Test("熔断账本自己打日志,首次与续期都打")
  func breakerLogsEveryMark() throws {
    let text = try source("Sources/Velto/AxDeadPids.swift")
    #expect(text.contains("static func mark(_ pid: pid_t, source:"))
    #expect(text.contains("WindowManagementDebugLog.log"))
    // 续期也要打:Chrome 那次连黑 10.4s 超过一个 TTL,只记首次看不出是被续命的。
    #expect(text.contains("🔌 AX 熔断"))
    #expect(text.contains("🔁 AX 熔断续期"))
  }

  /// 真跑一遍写文件路径 —— 结构断言证明不了 `isEnabled` 那道闸没把日志吃掉。
  /// 写的是真实的 window-management.log(它本来就是可丢弃的调试日志),
  /// 跑完把开关恢复原状。
  @Test("熔断日志真的落盘")
  func breakerLogActuallyWritesToFile() throws {
    let url = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Logs/Velto/window-management.log")
    let wasEnabled = WindowManagementDebugLog.isEnabled
    WindowManagementDebugLog.setEnabled(true)
    defer { WindowManagementDebugLog.setEnabled(wasEnabled) }

    let pid: pid_t = 0x7f_ff_fe  // 与上面那条测试错开,免得互相续期
    // tag 每跑一次都不同 —— 日志是追加写的,固定 tag 会把上次跑的两行也数进来。
    let tag = "熔断日志落盘自检-\(pid)-\(UUID().uuidString.prefix(8))"
    #expect(AxDeadPids.mark(pid, source: tag))       // 首次 → 🔌
    #expect(!AxDeadPids.mark(pid, source: tag))      // 再来 → 🔁

    let text = try String(contentsOf: url, encoding: .utf8)
    let mine = text.split(separator: "\n").filter { $0.contains(tag) }
    #expect(mine.count == 2)
    #expect(mine.contains { $0.contains("🔌 AX 熔断") })
    #expect(mine.contains { $0.contains("🔁 AX 熔断续期") })
    #expect(mine.allSatisfy { $0.contains("pid=\(pid)") })
  }

  /// 熔断期 `axWindow(matching:)` 返回 nil,`prepareForExecution` 就只剩 activate ——
  /// app 到前台但那个窗口没被选中,观感等同冻结(2026-08-27 Telegram 用户实报)。
  /// 必须用 CG 那份 wid 走 WindowServer 补上「选中」,且**不能**改回用 AX 补。
  @Test("熔断期用 WindowServer 选中窗口,不碰 AX")
  func breakerFallsBackToWindowServerFocus() throws {
    let target = try source("Sources/Velto/GestureTargetController.swift")
    let focus = try source("Sources/Velto/Switcher/SwitcherFocus.swift")

    // wid 要一路带到 GestureExecutionTarget,否则熔断时手上什么都没有
    #expect(target.contains("let cgWindowId: CGWindowID?"))
    #expect(target.contains("wid: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0"))
    #expect(target.contains("cgWindowId: candidate.wid == 0 ? nil : candidate.wid"))

    // 只在拿不到 AX 窗口时才走兜底 —— 有真窗口时 focus() 那条路更全(kAXMain/kAXFocused)
    let marker = "static func prepareForExecution("
    let start = try #require(target.range(of: marker))
    let body = target[start.upperBound...].prefix(1200)
    #expect(body.contains("if let window = target.window {"))
    #expect(body.contains("} else if let wid = target.cgWindowId {"))
    #expect(body.contains("SwitcherFocus.raiseByWindowServer(pid: pid, cgWindowId: wid)"))

    // 兜底本身必须零 AX:熔断的初衷就是别再打扰目标 app 的主线程。
    let fStart = try #require(focus.range(of: "static func raiseByWindowServer("))
    let fBody = focus[fStart.upperBound...].prefix(900)
    #expect(fBody.contains("_SLPSSetFrontProcessWithOptions"))
    #expect(fBody.contains("makeKeyWindow"))
    #expect(!fBody.contains("AXUIElement"))
    #expect(!fBody.contains("performAxRaise"))
  }

  /// AX 哑巴 app 的 ⌥ 拖窗口靠 WindowServer 兜底(它们本来就一直拖不动)。
  @Test("AX 拿不到窗口时改用 SLSMoveWindow")
  func dragFallsBackToWindowServer() throws {
    let drag = try source("Sources/Velto/WindowManagement/WindowDragController.swift")
    let sky = try source("Sources/Velto/Switcher/SkyLightPrivate.swift")
    let target = try source("Sources/Velto/GestureTargetController.swift")

    #expect(sky.contains("@_silgen_name(\"SLSMoveWindow\")"))
    #expect(target.contains("static func cgWindowUnderPointer(at point: CGPoint)"))
    #expect(drag.contains("SLSMoveWindow(CGS_CONNECTION, session.cgWindowID, &origin)"))
    #expect(drag.contains("GestureTargetController.cgWindowUnderPointer(at: location)"))

    // resize 没有等价兜底,CG 会话必须拒绝,别拿 SkyLight 改 shape。
    let marker = "case .resize:"
    let start = try #require(drag.range(of: marker))
    let body = drag[start.upperBound...].prefix(300)
    #expect(body.contains("guard let window = session.window else { return false }"))
    #expect(!body.contains("SLSMoveWindow"))
  }

  /// 目标查找必须离开协作线程池 —— 阻塞式 IPC 会把池线程整根占住。
  @Test("目标查找不跑在协作线程池上")
  func targetLookupAvoidsCooperativePool() throws {
    let text = try source("Sources/Velto/Gestures/GestureEngine.swift")

    #expect(text.contains("Self.targetLookupQueue.async"))
    // 注释里提 Task.detached 是在解释为什么不用它,只禁止真的调用。
    #expect(!text.contains("Task.detached("))
  }
}
