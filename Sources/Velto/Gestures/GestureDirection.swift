import CoreGraphics
import Foundation

/// 把一条鼠标轨迹压成「方向序列 + 弧向」的二维签名。
///
/// 实测用户的手势分两类:① 平滑的单笔挥动(直线或带弧度的斜划);② 带尖锐拐角的
/// 折返(如「←→」来回、「↓↗」对勾)。识别要同时照顾这两类,于是:
///
///   - **拐角检测**:沿轨迹算每点局部转角,只有转角够大(尖锐折返/直角)才切一刀;
///     平滑的弧不切 —— 整笔只取「起点→终点」的净方向。这样弧度大小不影响方向序列。
///   - **弧向(有符号曲率)**:净方向相同的两笔(如都 ↗),再看相对弦线往哪边凸 ——
///     这正是用户区分「下弧 / 上弧」用的维度。**只在净方向完全相同时**才用弧向区分,
///     不放宽相邻方向(否则水平右滑会误命中斜上方的弧手势)。
///
/// 方向桶(屏幕坐标系,y 向下):
///
///       6 ↑
///   5 ↖     7 ↗
/// 4 ←    •    0 →
///   3 ↙     1 ↘
///       2 ↓
///
/// 全部是无状态纯函数,识别器(后台 tap 线程经主线程)与设置页(SwiftUI 主线程)
/// 都能直接调用,不引入 actor 隔离。
enum GestureDirection {
    /// 一条手势的签名:方向序列 + 弧向(有符号曲率 = 平均垂距 ÷ 弦长,
    /// >0 为 ⌣ 下弧,<0 为 ⌢ 上弧)。
    struct Signature: Equatable, Sendable {
        var sequence: [Int]
        var bow: CGFloat

        static let empty = Signature(sequence: [], bow: 0)
        var isEmpty: Bool { sequence.isEmpty }
        /// 弧向三态符号:+1 下弧 / 0 直 / −1 上弧。
        var bowSign: Int { GestureDirection.bowSign(bow) }
    }

    /// 等弧长重采样点数。重采样后每一步等长,转角与垂距计算不受原始采样疏密影响。
    static let sampleCount = 64

    /// 轨迹总长(像素)低于此值视为误触/点按,不成手势。
    static let minimumPathLength: CGFloat = 24

    /// 拐角检测前后窗口(单位:重采样点)。第 i 点比较 [i−w, i] 与 [i, i+w] 两段夹角。
    static let cornerWindow = 6

    /// 判为「拐角」的转角阈值。平滑弧每点转角实测 ≤25°,尖锐折返/直角 ≥90°,55° 居中。
    static let cornerAngleThreshold: CGFloat = 55 * .pi / 180

    /// 判定弧向符号的阈值:|弧向| 超过它才算「确有弧向」。
    static let bowSignThreshold: CGFloat = 0.025

    /// 「强弧」阈值:超过它的弧,即便对手是直线也要区分(避免强弧手势误命中同方向直线
    /// 手势)。设得比 `bowSignThreshold` 高,好让直线被随手画弯一点也不会触发。
    static let bowStrongThreshold: CGFloat = 0.06

    /// 两笔净方向相同、弧向相反(一上一下)时叠加的距离惩罚。
    static let bowOppositePenalty: CGFloat = 0.6

    /// 一笔是强弧、另一笔是直线时叠加的距离惩罚。0.4 足以越过识别阈值(默认 0.34)。
    static let bowStraightPenalty: CGFloat = 0.4

    /// 多段序列编辑距离里「相邻方向桶(45°)」的替换代价。折返手势的竖/斜笔画常骑在
    /// 45° 桶边界上(模板录成 ↓↗、实际画出 ↓↑),按整错记 1 会把这种只差一档的手势
    /// 直接推过识别阈值(两段序列一档 = 0.5 > 0.34)。0.25 让「一档之差」稳稳落在
    /// 阈值内(双腿都差一档 = 0.25),又不至于把差两档(90°)的真不同手势拉进来。
    static let adjacentSubstitutionCost: CGFloat = 0.25

    private static let glyphs = ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]

    // MARK: - 主入口

    /// 轨迹 → 签名。空签名(sequence 为空)表示「太短 / 无法识别」。
    static func signature(from points: [CGPoint]) -> Signature {
        let total = pathLength(points)
        guard total >= minimumPathLength else { return .empty }

        let resampled = resample(points, targetCount: sampleCount, knownPathLength: total)
        guard resampled.count >= 2 else { return .empty }

        let sequence = directionSequence(of: resampled)
        guard !sequence.isEmpty else { return .empty }

        return Signature(sequence: sequence, bow: bowMetric(of: resampled))
    }

    /// 一组样本 → 该命令的「规范签名」。方向序列取众数;弧向取该序列样本的弧向平均值。
    /// 旧数据自动迁移、无需重录。平票时取最后录入的样本。全部太短则返回空签名。
    static func canonical(for samples: [[CGPoint]]) -> Signature {
        let sigs = samples.map { signature(from: $0) }.filter { !$0.isEmpty }
        guard !sigs.isEmpty else { return .empty }

        var counts: [[Int]: Int] = [:]
        for sig in sigs { counts[sig.sequence, default: 0] += 1 }
        let top = counts.values.max() ?? 0

        var canonicalSeq: [Int] = sigs.last?.sequence ?? []
        for sig in sigs.reversed() where counts[sig.sequence] == top {
            canonicalSeq = sig.sequence
            break
        }

        let bows = sigs.filter { $0.sequence == canonicalSeq }.map(\.bow)
        let averageBow = bows.isEmpty ? 0 : bows.reduce(0, +) / CGFloat(bows.count)
        return Signature(sequence: canonicalSeq, bow: averageBow)
    }

    /// 两个签名的「差异度」,0 = 完全一致。单段手势比较方向 + 弧向;多段折返手势
    /// 只比较方向序列,避免「←→」因为保存样本略带弧度而被误判成不命中。
    static func distance(_ lhs: Signature, _ rhs: Signature) -> CGFloat {
        let seqDistance: CGFloat
        if lhs.sequence.count == 1, rhs.sequence.count == 1,
           lhs.bowSign != 0, lhs.bowSign == rhs.bowSign,
           circularBucketDistance(lhs.sequence[0], rhs.sequence[0]) <= 1 {
            // 单段、同弧向、净方向仅差一个相邻方向桶 → 视为同方向。半圆类弧手势的弦方向
            // 会在 45° 桶边界两侧抖动(如上半圆对称画时净 →、画斜时净 ↗),此时靠弧向就能
            // 区分,方向放宽一档。只在"两者都确有同向弧"时放宽:直线/折返(弧向=直)不享此
            // 放宽,故 前进(→,直) 与 下一个Tab(↗,上弧) 仍靠方向严格区分,不会牵连。
            seqDistance = 0
        } else {
            seqDistance = sequenceDistance(lhs.sequence, rhs.sequence)
        }
        guard lhs.sequence.count == 1, rhs.sequence.count == 1 else {
            return seqDistance
        }
        return seqDistance + bowPenalty(lhs.bow, rhs.bow)
    }

    /// 两个方向桶在 0…7 环上的最短距离(0 = 同向,1 = 相邻 45°)。
    private static func circularBucketDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b) % 8
        return min(d, 8 - d)
    }

    /// 人类可读箭头串(如 "↗→"),用于设置页展示与调试日志。
    static func arrows(_ sequence: [Int]) -> String {
        sequence.map { glyphs[$0] }.joined()
    }

    /// 人类可读签名。单段弧线显示弧向;多段折返只显示方向序列。
    static func displayString(_ signature: Signature) -> String {
        arrows(signature.sequence) + (signature.sequence.count == 1 ? bowGlyph(signature.bowSign) : "")
    }

    /// 弧向标记:⌢ 上弧 / ⌣ 下弧 / 空(直)。入参为 `Signature.bowSign`。
    static func bowGlyph(_ sign: Int) -> String {
        switch sign {
        case 1: return "⌣"
        case -1: return "⌢"
        default: return ""
        }
    }

    static func bowSign(_ bow: CGFloat) -> Int {
        if bow > bowSignThreshold { return 1 }
        if bow < -bowSignThreshold { return -1 }
        return 0
    }

    // MARK: - 方向序列(拐角分段 + 每段净方向)

    /// 在尖锐拐角处切分轨迹,每段取「段首→段尾」的净方向并量化;平滑段不切,整段一个
    /// 净方向。相邻同向段合并。
    static func directionSequence(of points: [CGPoint]) -> [Int] {
        let n = points.count
        let w = cornerWindow
        guard n > 2 * w + 1 else {
            return netDirection(points, from: 0, to: n - 1).map { [$0] } ?? []
        }

        var turns = [CGFloat](repeating: 0, count: n)
        for i in w..<(n - w) {
            let ax = points[i].x - points[i - w].x
            let ay = points[i].y - points[i - w].y
            let bx = points[i + w].x - points[i].x
            let by = points[i + w].y - points[i].y
            let na = hypot(ax, ay)
            let nb = hypot(bx, by)
            guard na > 0, nb > 0 else { continue }
            let cosine = max(-1, min(1, (ax * bx + ay * by) / (na * nb)))
            turns[i] = acos(cosine)
        }

        var corners: [Int] = []
        for i in w..<(n - w) {
            guard turns[i] > cornerAngleThreshold else { continue }
            let lower = max(0, i - w)
            let upper = min(n - 1, i + w)
            if (lower...upper).contains(where: { turns[$0] > turns[i] }) { continue }
            if let last = corners.last, i - last <= w { continue }
            corners.append(i)
        }

        let bounds = [0] + corners + [n - 1]
        var sequence: [Int] = []
        for k in 0..<(bounds.count - 1) {
            guard let dir = netDirection(points, from: bounds[k], to: bounds[k + 1]) else { continue }
            if sequence.last != dir { sequence.append(dir) }
        }
        return sequence
    }

    private static func netDirection(_ points: [CGPoint], from a: Int, to b: Int) -> Int? {
        let dx = points[b].x - points[a].x
        let dy = points[b].y - points[a].y
        guard dx != 0 || dy != 0 else { return nil }
        return quantize(dx: dx, dy: dy)
    }

    /// atan2 → 最近的 45° 方向桶(0…7)。
    static func quantize(dx: CGFloat, dy: CGFloat) -> Int {
        let step = CGFloat.pi / 4
        let bucket = Int((atan2(dy, dx) / step).rounded())
        return ((bucket % 8) + 8) % 8
    }

    // MARK: - 弧向(有符号曲率)

    /// 轨迹相对「起点→终点」弦线的平均有符号垂距,归一化到弦长。
    /// 近似闭合(弦长远小于路径)时弦法失效,直接判 0。
    static func bowMetric(of points: [CGPoint]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        let cx = last.x - first.x
        let cy = last.y - first.y
        let chord = hypot(cx, cy)
        guard chord > 0, chord >= 0.2 * pathLength(points) else { return 0 }

        let ux = cx / chord
        let uy = cy / chord
        var sum: CGFloat = 0
        for point in points {
            sum += ux * (point.y - first.y) - uy * (point.x - first.x)   // 有符号垂距(叉积)
        }
        return (sum / CGFloat(points.count)) / chord
    }

    // MARK: - 私有辅助

    /// 弧向惩罚:净方向相同才有意义(序列不同时序列差异度已足够区分)。
    ///   - 一上弧一下弧 → 强惩罚;
    ///   - 一强弧一直线 → 中惩罚;
    ///   - 其余(同向、或都接近直)→ 不罚,避免误伤被随手画弯的直线手势。
    private static func bowPenalty(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let signLhs = bowSign(lhs)
        let signRhs = bowSign(rhs)
        if signLhs == 0, signRhs == 0 { return 0 }
        if signLhs != 0, signRhs != 0, signLhs != signRhs { return bowOppositePenalty }
        if signLhs == 0 || signRhs == 0 {
            return max(abs(lhs), abs(rhs)) > bowStrongThreshold ? bowStraightPenalty : 0
        }
        return 0
    }

    /// 方向序列差异度,归一化到约 [0, 1]:0 = 完全一致。加权编辑距离 ÷ 较长序列长度。
    ///
    /// 只要任一序列是多段(折返),替换代价就分级:相邻方向桶只记
    /// `adjacentSubstitutionCost`,其余仍记 1。单段 vs 单段保持严格二值 —— 单段的
    /// 相邻方向放宽由 `distance` 的「同弧向」判据把关,这里再放宽会让 → 直线与 ↗
    /// 直线互相误命中。
    private static func sequenceDistance(_ lhs: [Int], _ rhs: [Int]) -> CGFloat {
        if lhs == rhs { return 0 }
        if lhs.isEmpty || rhs.isEmpty { return 1 }
        let graded = lhs.count > 1 || rhs.count > 1
        return levenshtein(lhs, rhs, graded: graded) / CGFloat(max(lhs.count, rhs.count))
    }

    /// 加权动态规划编辑距离(两行滚动数组)。序列很短(通常 1~3),开销可忽略。
    private static func levenshtein(_ lhs: [Int], _ rhs: [Int], graded: Bool) -> CGFloat {
        var previous = (0...rhs.count).map(CGFloat.init)
        var current = [CGFloat](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = CGFloat(i)
            for j in 1...rhs.count {
                let cost = substitutionCost(lhs[i - 1], rhs[j - 1], graded: graded)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    private static func substitutionCost(_ a: Int, _ b: Int, graded: Bool) -> CGFloat {
        if a == b { return 0 }
        if graded, circularBucketDistance(a, b) == 1 { return adjacentSubstitutionCost }
        return 1
    }

    // MARK: - 几何

    static func resample(_ points: [CGPoint], targetCount: Int, knownPathLength: CGFloat?) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard targetCount > 1 else { return [first] }

        let totalLength = knownPathLength ?? pathLength(points)
        guard totalLength > 0 else { return Array(repeating: first, count: targetCount) }

        let interval = totalLength / CGFloat(targetCount - 1)
        var result = [first]
        result.reserveCapacity(targetCount)

        var accumulated: CGFloat = 0
        var segmentStart = first

        for segmentEnd in points.dropFirst() {
            var remainingDistance = distance(segmentStart, segmentEnd)
            while remainingDistance > 0, accumulated + remainingDistance >= interval {
                let needed = interval - accumulated
                let ratio = needed / remainingDistance
                let point = CGPoint(
                    x: segmentStart.x + ratio * (segmentEnd.x - segmentStart.x),
                    y: segmentStart.y + ratio * (segmentEnd.y - segmentStart.y)
                )
                result.append(point)
                if result.count == targetCount { return result }
                segmentStart = point
                remainingDistance = distance(segmentStart, segmentEnd)
                accumulated = 0
            }
            accumulated += remainingDistance
            segmentStart = segmentEnd
        }

        while result.count < targetCount {
            result.append(points.last ?? result.last ?? .zero)
        }
        return result
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        return (1..<points.count).reduce(CGFloat(0)) { partial, index in
            partial + distance(points[index - 1], points[index])
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
