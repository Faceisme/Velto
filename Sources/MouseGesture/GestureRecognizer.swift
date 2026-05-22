import CoreGraphics
import Foundation

struct GestureMatch {
    var command: GestureCommand
    var distance: CGFloat
}

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
        let candidatePathLength = pathLength(points)
        guard candidatePathLength >= minimumPathLength,
              let candidate = normalize(points, knownPathLength: candidatePathLength) else {
            return nil
        }

        var best: GestureMatch?

        for template in normalizedTemplates(for: commands, version: version) {
            let distance = averageDistance(candidate, template.points)
            if best == nil || distance < best!.distance {
                best = GestureMatch(command: template.command, distance: distance)
            }
        }

        return best
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
