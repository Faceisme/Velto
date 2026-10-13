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
    /// 上次构建缓存所依据的 `GestureStore.gesturesVersion`,版本一变整张表作废。
    private var cachedVersion: UInt64?
    /// 命令 id → 规范签名(众数,可能为空 —— 样本全部太短)。按 id 缓存而不是按整张
    /// 命令表:每个 App 参与匹配的是不同的子集(App 手势 + 没被覆盖的全局手势),
    /// 子集各异但同一个命令的签名只算一次。
    private var cachedSignatures: [UUID: GestureDirection.Signature] = [:]

    /// 同时求最近邻 `best` 与次近邻差异度 `runnerUpDistance`(命令 < 2 个时为 nil)。
    /// 调用方据「次近 − 最近」的余量判断手势是否卡在两个命令之间而模糊。
    func bestCandidates(points: [CGPoint], commands: [GestureCommand], version: UInt64) -> GestureCandidates? {
        let candidate = GestureDirection.signature(from: points)
        guard !candidate.isEmpty else { return nil }

        let ranked = commands
            .map { ($0, signature(for: $0, version: version)) }
            .filter { !$0.1.isEmpty }
            .map { GestureMatch(command: $0.0, distance: GestureDirection.distance(candidate, $0.1)) }
            .sorted { $0.distance < $1.distance }

        guard let best = ranked.first else { return nil }
        return GestureCandidates(best: best, runnerUpDistance: ranked.count > 1 ? ranked[1].distance : nil)
    }

    /// 单个命令的规范签名(走缓存)。供运行时叠加全局 / App 手势、调试日志使用。
    func signature(for command: GestureCommand, version: UInt64) -> GestureDirection.Signature {
        if cachedVersion != version {
            cachedVersion = version
            cachedSignatures.removeAll(keepingCapacity: true)
        }
        if let cached = cachedSignatures[command.id] {
            return cached
        }
        let signature = GestureDirection.canonical(for: command.templates.map { $0.map(\.cgPoint) })
        cachedSignatures[command.id] = signature
        return signature
    }
}
