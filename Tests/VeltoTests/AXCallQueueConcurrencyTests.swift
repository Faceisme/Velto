import Foundation
import Synchronization
import Testing

@testable import Velto

/// 后台 AX 队列从串行改成有界并发(`maxConcurrentOperationCount = 4`)后要守住的两条。
///
/// 背景:暴力枚举去掉 id 上限后,每个 app 稳定烧满预算,串行队列上 N 个 app 的启动
/// 扫描就线性叠加。改并发是为了压掉这个。同 key = 同一个 pid/wid,两路
/// `applyProbes` 乱序落到 MainActor 就是窗口误删(见 switcher-window-churn 那一堆坑),
/// 串行队列白送的这条保证,并发队列必须靠 `op.addDependency(previous)` 自己挂。
///
/// 第一版还踩了个坑:节流原本用 `previous?.cancel()`,而 cancelled 的 operation 会
/// **立即 finish 而不等自己的依赖**,后面的同 key 就被提前放行,这个用例当场抓到
/// peak=2。所以节流改成字典身份判断,作废的 op 照样占着链上的位置。
///
/// 共享 `AXCallQueue.shared` 的槽位,必须串行跑,否则两个用例互相抢槽。
@Suite(.serialized)
struct AXCallQueueConcurrencyTests {
  private struct Trace: Sendable {
    var inFlight = 0
    var peak = 0
    var overlapped = false
    var completed = 0

    mutating func enter() {
      inFlight += 1
      peak = max(peak, inFlight)
      if inFlight > 1 { overlapped = true }
    }

    mutating func leave() {
      inFlight -= 1
      completed += 1
    }
  }

  private func waitUntil(
    timeout: TimeInterval = 5.0,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("等待条件超时(\(timeout)s)")
  }

  @Test("同 key 绝不重叠 —— 靠 addDependency 把并发槽上的同 key 拉回串行")
  func sameKeyNeverOverlaps() async {
    let trace = Mutex(Trace())
    let key = "velto-test-same-\(UUID().uuidString)"
    let body: @Sendable () -> Void = {
      trace.withLock { $0.enter() }
      Thread.sleep(forTimeInterval: 0.05)
      trace.withLock { $0.leave() }
    }

    AXCallQueue.shared.schedule(key, body)
    // 等第一个真正进入执行 —— 这正是 cancel 失效、只能靠依赖的那个窗口期。
    await waitUntil { trace.withLock { $0.inFlight == 1 } }
    for _ in 0..<7 {
      AXCallQueue.shared.schedule(key, body)
    }

    await waitUntil { trace.withLock { $0.inFlight == 0 && $0.completed >= 2 } }
    #expect(trace.withLock { $0.overlapped } == false)
    #expect(trace.withLock { $0.peak } == 1)
  }

  @Test("不同 key 真并发 —— 否则这次改动等于没做")
  func distinctKeysRunConcurrently() async {
    let trace = Mutex(Trace())
    for i in 0..<4 {
      AXCallQueue.shared.schedule("velto-test-distinct-\(UUID().uuidString)-\(i)") {
        trace.withLock { $0.enter() }
        Thread.sleep(forTimeInterval: 0.05)
        trace.withLock { $0.leave() }
      }
    }

    await waitUntil { trace.withLock { $0.completed == 4 } }
    // 不断言 == 4,调度抖动会让它偶尔只叠到 2、3;> 1 就证明串行锁已经解开。
    #expect(trace.withLock { $0.peak } > 1)
  }

  @Test("节流仍在:同 key 连排一批,被顶掉的空跑退出,不会全部执行")
  func sameKeyStillThrottles() async {
    let trace = Mutex(Trace())
    let key = "velto-test-throttle-\(UUID().uuidString)"
    for _ in 0..<8 {
      AXCallQueue.shared.schedule(key) {
        trace.withLock { $0.enter() }
        Thread.sleep(forTimeInterval: 0.02)
        trace.withLock { $0.leave() }
      }
    }

    await waitUntil { trace.withLock { $0.inFlight == 0 && $0.completed >= 1 } }
    #expect(trace.withLock { $0.completed } < 8)
  }
}
