import CoreGraphics
import Foundation

struct GestureMatch: Sendable {
    var command: GestureCommand
    var distance: CGFloat
}

/// 一次匹配的最近邻与次近邻信息。`runnerUpDistance` 为次近模板的距离
/// (模板少于 2 个时为 `nil`),用于"最近/次近余量"判据。
struct GestureCandidates: Sendable {
    var best: GestureMatch
    var runnerUpDistance: CGFloat?
}

/// 模板归一化 + 最近邻匹配。
///
/// `@MainActor`:内部 `cachedVersion` / `cachedTemplates` 没有锁保护,但 Swift 6
/// 的隔离规则强制所有调用必须在主线程发生 — `GestureEngine.runGesture` 经
/// `Task { @MainActor }` 进入即可。如果将来要把匹配挪到后台线程,需要给每个
/// 调用方分配独立 recognizer,或者把缓存换成 actor。
@MainActor
final class GestureRecognizer {
    private struct NormalizedTemplate {
        var command: GestureCommand
        var points: [CGPoint]
    }

    private let sampleCount = 64
    private let minimumPathLength: CGFloat = 24
    /// Last `GestureStore.gesturesVersion` the cache was built against.
    /// `nil` means cache is empty / invalidated.
    private var cachedVersion: UInt64?
    private var cachedTemplates: [NormalizedTemplate] = []

    func bestMatch(points: [CGPoint], commands: [GestureCommand], version: UInt64, threshold: CGFloat) -> GestureMatch? {
        guard let best = bestCandidate(points: points, commands: commands, version: version) else {
            return nil
        }

        guard best.distance <= threshold else {
            return nil
        }

        return best
    }

    func bestCandidate(points: [CGPoint], commands: [GestureCommand], version: UInt64) -> GestureMatch? {
        bestCandidates(points: points, commands: commands, version: version)?.best
    }

    /// 同时求最近邻 `best` 与次近邻距离 `runnerUpDistance`(命令 <2 个时为 nil)。
    /// 调用方据"次近 - 最近"的余量判断手势是否卡在两个命令之间而模糊。
    ///
    /// 关键:次近邻是"次近的**命令**",不是"次近的模板"。同一命令常有多条模板
    /// (用户把同一手势录了多遍),它们彼此很近是正常的,绝不能算作歧义。先把每个
    /// 命令压成它所有模板里的最小距离,再在命令层面取最近/次近。
    func bestCandidates(points: [CGPoint], commands: [GestureCommand], version: UInt64) -> GestureCandidates? {
        let candidatePathLength = pathLength(points)
        guard candidatePathLength >= minimumPathLength,
              let candidate = normalize(points, knownPathLength: candidatePathLength) else {
            return nil
        }

        var perCommand: [GestureCommand.ID: GestureMatch] = [:]
        for template in normalizedTemplates(for: commands, version: version) {
            let distance = averageDistance(candidate, template.points)
            if let existing = perCommand[template.command.id], existing.distance <= distance {
                continue
            }
            perCommand[template.command.id] = GestureMatch(command: template.command, distance: distance)
        }

        let ranked = perCommand.values.sorted { $0.distance < $1.distance }
        guard let best = ranked.first else { return nil }
        return GestureCandidates(best: best, runnerUpDistance: ranked.count > 1 ? ranked[1].distance : nil)
    }

    func normalize(_ points: [CGPoint]) -> [CGPoint]? {
        normalize(points, knownPathLength: nil)
    }

    private func normalize(_ points: [CGPoint], knownPathLength: CGFloat?) -> [CGPoint]? {
        guard points.count >= 2 else {
            return nil
        }

        let resampled = resample(points, targetCount: sampleCount, knownPathLength: knownPathLength)
        guard let scaled = scaleToUnitBox(resampled) else {
            return nil
        }

        return translateToOrigin(scaled)
    }

    private func normalizedTemplates(for commands: [GestureCommand], version: UInt64) -> [NormalizedTemplate] {
        if cachedVersion == version {
            return cachedTemplates
        }

        let templates = commands.flatMap { command in
            command.templates.compactMap { template -> NormalizedTemplate? in
                guard let points = normalize(template.map(\.cgPoint)) else {
                    return nil
                }
                return NormalizedTemplate(command: command, points: points)
            }
        }

        cachedVersion = version
        cachedTemplates = templates
        return templates
    }

    private func resample(_ points: [CGPoint], targetCount: Int, knownPathLength: CGFloat?) -> [CGPoint] {
        guard let first = points.first else {
            return []
        }

        guard targetCount > 1 else {
            return [first]
        }

        let totalLength = knownPathLength ?? pathLength(points)
        guard totalLength > 0 else {
            return Array(repeating: first, count: targetCount)
        }

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
                if result.count == targetCount {
                    return result
                }

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

    private func scaleToUnitBox(_ points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first else {
            return nil
        }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let scale = max(maxX - minX, maxY - minY)
        guard scale > 0.0001 else {
            return nil
        }

        return points.map { point in
            CGPoint(
                x: (point.x - minX) / scale,
                y: (point.y - minY) / scale
            )
        }
    }

    private func translateToOrigin(_ points: [CGPoint]) -> [CGPoint] {
        let center = centroid(points)
        return points.map { point in
            CGPoint(x: point.x - center.x, y: point.y - center.y)
        }
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }

        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func averageDistance(_ left: [CGPoint], _ right: [CGPoint]) -> CGFloat {
        let count = min(left.count, right.count)
        guard count > 0 else {
            return .greatestFiniteMagnitude
        }

        let total = (0..<count).reduce(CGFloat(0)) { partial, index in
            partial + distance(left[index], right[index])
        }

        return total / CGFloat(count)
    }

    private func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else {
            return 0
        }

        return (1..<points.count).reduce(CGFloat(0)) { partial, index in
            partial + distance(points[index - 1], points[index])
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
