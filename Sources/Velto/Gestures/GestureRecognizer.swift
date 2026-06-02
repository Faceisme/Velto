import CoreGraphics
import Foundation

struct GestureMatch: Sendable {
    var command: GestureCommand
    /// 候选轨迹与该命令「规范签名(方向序列 + 弧向)」的差异度
    /// (见 `GestureDirection.distance`):0 = 完全一致,越大越不像。
    var distance: CGFloat
}

/// 一次匹配的最近邻与次近邻信息。`runnerUpDistance` 为次近命令的差异度
/// (命令少于 2 个时为 `nil`),用于「最近 / 次近余量」判据。
struct GestureCandidates: Sendable {
    var best: GestureMatch
    var runnerUpDistance: CGFloat?
}

/// 签名匹配器。把每个命令压成一条「规范签名(方向序列 + 弧向)」,再拿用户当次画的
/// 轨迹签名去逐命令比差异度,取最近邻。
///
/// 方向序列对大小/速度/起点无关、录 1 次即可、冲突在配置期即可判定;弧向维度又能拆开
/// 「同向不同弧」(如下弧 / 上弧)这类纯方向分不开的手势。详见 `GestureDirection`。
///
/// `@MainActor`:`cachedSignatures` 无锁,靠 Swift 6 隔离规则强制所有调用在主线程
/// 发生(`GestureEngine.runGesture` 经 `Task { @MainActor }` 进入)。
@MainActor
final class GestureRecognizer {
    private struct CommandSignature {
        let command: GestureCommand
        /// 该命令的规范签名(众数)。可能为空(样本全部太短)。
        let signature: GestureDirection.Signature
    }

    /// 上次构建缓存所依据的 `GestureStore.gesturesVersion`,`nil` 表示缓存已失效。
    private var cachedVersion: UInt64?
    private var cachedSignatures: [CommandSignature] = []

    /// 同时求最近邻 `best` 与次近邻差异度 `runnerUpDistance`(命令 < 2 个时为 nil)。
    /// 调用方据「次近 − 最近」的余量判断手势是否卡在两个命令之间而模糊。
    func bestCandidates(points: [CGPoint], commands: [GestureCommand], version: UInt64) -> GestureCandidates? {
        let candidate = GestureDirection.signature(from: points)
        guard !candidate.isEmpty else { return nil }

        let ranked = commandSignatures(for: commands, version: version)
            .filter { !$0.signature.isEmpty }
            .map { GestureMatch(command: $0.command, distance: GestureDirection.distance(candidate, $0.signature)) }
            .sorted { $0.distance < $1.distance }

        guard let best = ranked.first else { return nil }
        return GestureCandidates(best: best, runnerUpDistance: ranked.count > 1 ? ranked[1].distance : nil)
    }

    /// 单个命令的规范签名。供设置页展示箭头 / 冲突检测、调试日志使用。
    func canonicalSignature(for command: GestureCommand) -> GestureDirection.Signature {
        GestureDirection.canonical(for: command.templates.map { $0.map(\.cgPoint) })
    }

    private func commandSignatures(for commands: [GestureCommand], version: UInt64) -> [CommandSignature] {
        if cachedVersion == version {
            return cachedSignatures
        }

        let signatures = commands.map { command in
            CommandSignature(
                command: command,
                signature: GestureDirection.canonical(for: command.templates.map { $0.map(\.cgPoint) })
            )
        }

        cachedVersion = version
        cachedSignatures = signatures
        return signatures
    }
}
