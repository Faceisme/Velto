import Foundation
import Testing

@testable import Velto

/// 2026-10-26 22:36 闪退回归:专注自动化每秒问 Movist Pro 窗口里载入了什么文件,原来写的是
/// `pids.lazy.compactMap(loadedMediaName).first`,对命中的 pid 会问两次 AX。视频窗口正在关时
/// 第二次拿到 nil,标准库里的强制解包直接崩。这里用「同一个 pid 第二次问就返回 nil」模拟那一刻。
@Test func firstNonNilAsksEachPidOnlyOnce() {
  var calls: [pid_t: Int] = [:]
  let name = Set<pid_t>([5895]).firstNonNil { pid -> String? in
    calls[pid, default: 0] += 1
    return calls[pid] == 1 ? "PRWF-017-UC.mp4" : nil
  }
  #expect(name == "PRWF-017-UC.mp4")
  #expect(calls == [5895: 1])
}

/// 命中就停,后面的不再问;全都没有返回 nil。
@Test func firstNonNilStopsAtFirstHit() {
  var asked: [pid_t] = []
  let name = [pid_t(3), 7, 11].firstNonNil { pid -> String? in
    asked.append(pid)
    return pid == 7 ? "movie.mp4" : nil
  }
  #expect(name == "movie.mp4")
  #expect(asked == [3, 7])
  #expect([pid_t(3), 11].firstNonNil { _ -> String? in nil } == nil)
}
