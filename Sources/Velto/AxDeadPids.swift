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
/// ponytail: 一次失败即熔断 5s。偶发超时会让健康 app 短暂降级,
/// 若实际误伤明显再改成连续 N 次失败才熔断。
enum AxDeadPids {
  private static let ttl: CFAbsoluteTime = 5.0
  private static let entries = Mutex<[pid_t: CFAbsoluteTime]>([:])

  static func isDead(_ pid: pid_t) -> Bool {
    entries.withLock { $0[pid].map { CFAbsoluteTimeGetCurrent() < $0 } ?? false }
  }

  /// 返回 `true` 表示这次是**新**熔断(之前没在黑名单里),给调用方决定要不要打日志。
  @discardableResult
  static func mark(_ pid: pid_t) -> Bool {
    let wasAlive = !isDead(pid)
    entries.withLock { $0[pid] = CFAbsoluteTimeGetCurrent() + ttl }
    return wasAlive
  }

  static var ttlSeconds: CFAbsoluteTime { ttl }
}
