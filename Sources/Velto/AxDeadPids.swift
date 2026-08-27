import CoreGraphics
import Foundation
import Synchronization

/// **对 AX 装哑巴的 app 的 pid 级熔断**,手势路径与切换器共用一份账。
///
/// macOS 27 实测(Telegram):`kAXWindows` 返回 **0 个窗口**却要花 53ms;暴力枚举
/// 333 次 RPC 打满 100ms 预算找到 0 个窗口;单次 AX RPC 约 0.30ms vs Chrome
/// 0.035ms(**慢 10 倍**)。微信 / 富途牛牛 / QQ音乐 等同样零窗口暴露。
///
/// 关键在于**这些开销全压在目标 app 自己的主线程上**,而我们超时放弃并不会让对方
/// 停手 —— 请求照样在它队列里堆着。手势密集时就表现为窗口点不动、交通灯没反应。
/// 既然问了也拿不到窗口,问出一次空结果就记一笔,TTL 内别再打扰它。
///
/// 注意这是**间歇性**的:同一个 pid 的 Telegram 可能这一分钟哑巴、下一分钟正常
/// (见 window-management.log 14:07 window=nil vs 14:14 window=有),所以用短 TTL
/// 自动恢复,而不是永久拉黑。app 重启换 pid,缓存也自然失效。
///
/// ponytail: 一次失败即熔断 5s,没做"连续 N 次才拉黑"的计数器。2026-08-26 那次
/// Chrome 误伤查下来根本不是采样抖动,是切换器的判据写错了(只看暴力枚举超时,
/// 没看标准路径已经拿到窗口),补一个条件就没了 —— 计数器只会把它盖住。
/// **判据要求两条 AX 路径同时空手**,这本身就够严了,真要再加计数器先拿日志说话。
enum AxDeadPids {
  private static let ttl: CFAbsoluteTime = 5.0
  private static let entries = Mutex<[pid_t: CFAbsoluteTime]>([:])

  static func isDead(_ pid: pid_t) -> Bool {
    entries.withLock { $0[pid].map { CFAbsoluteTimeGetCurrent() < $0 } ?? false }
  }

  /// 返回 `true` 表示这次是**新**熔断(之前没在黑名单里)。
  ///
  /// **日志打在账本里,不在调用点** —— 2026-08-26 排查 Chrome 被误熔断时,
  /// window-management.log 里 9 条 `⏭️ 已 AX 熔断` 却一条 `🔌` 都没有:
  /// 切换器那个调用点当时不打日志,查不出是谁下的手。放这儿之后,任何调用点
  /// 都别想再悄悄拉黑一个 app。
  ///
  /// 续期(`wasAlive == false`)也要打:Chrome 那次连续黑了 10.4s、超过一个
  /// TTL,就是被反复续命续出来的,只记首次根本看不出来。
  @discardableResult
  static func mark(_ pid: pid_t, source: @autoclosure () -> String) -> Bool {
    let wasAlive = !isDead(pid)
    entries.withLock { $0[pid] = CFAbsoluteTimeGetCurrent() + ttl }
    if WindowManagementDebugLog.isEnabled {
      let tag = wasAlive ? "🔌 AX 熔断" : "🔁 AX 熔断续期"
      WindowManagementDebugLog.log("  \(tag) pid=\(pid) \(ttl)s(\(source()))→ 后续走 CGWindowList")
    }
    return wasAlive
  }

  static var ttlSeconds: CFAbsoluteTime { ttl }
}
