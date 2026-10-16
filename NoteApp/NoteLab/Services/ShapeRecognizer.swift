import UIKit
import PencilKit

/// 손으로 그린 획을 직선·삼각형·사각형·원/타원으로 보정
enum ShapeRecognizer {
    /// 보정된 폴리라인(페이지 좌표). 알아볼 수 없으면 nil.
    static func recognize(_ stroke: PKStroke) -> [CGPoint]? {
        let pts = stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
        guard pts.count >= 6, let first = pts.first, let last = pts.last else { return nil }
        let box = bounding(pts)
        let size = max(box.width, box.height)
        guard size > 24 else { return nil }

        var length: CGFloat = 0
        for i in 1..<pts.count { length += dist(pts[i - 1], pts[i]) }
        let gap = dist(first, last)

        // 직선
        if gap / length > 0.92 {
            let maxDev = pts.map { distanceToSegment($0, first, last) }.max() ?? 0
            if maxDev < max(6, length * 0.05) { return [first, last] }
        }

        // 닫힌 도형만
        guard gap < size * 0.25 else { return nil }
        var closedPts = pts
        closedPts.append(first)
        var simplified = rdp(closedPts, epsilon: max(4, length * 0.035))
        if simplified.count > 1, dist(simplified[0], simplified[simplified.count - 1]) < size * 0.2 {
            simplified.removeLast()
        }

        switch simplified.count {
        case 3:
            return simplified + [simplified[0]]
        case 4:
            if isAxisAligned(simplified) {
                let b = bounding(simplified)
                return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                        CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.minX, y: b.minY)]
            }
            return simplified + [simplified[0]]
        default:
            let c = CGPoint(x: box.midX, y: box.midY)
            var rx = box.width / 2, ry = box.height / 2
            guard rx > 4, ry > 4 else { return nil }
            let err = pts.map { p -> CGFloat in
                let dx = (p.x - c.x) / rx, dy = (p.y - c.y) / ry
                return abs(sqrt(dx * dx + dy * dy) - 1)
            }.reduce(0, +) / CGFloat(pts.count)
            guard err < 0.12 else { return nil }
            if abs(rx - ry) / max(rx, ry) < 0.15 {
                let r = (rx + ry) / 2
                rx = r; ry = r
            }
            return (0...72).map { i in
                let a = 2 * CGFloat.pi * CGFloat(i) / 72
                return CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
            }
        }
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func bounding(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Ramer–Douglas–Peucker 단순화
    private static func rdp(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0
        var index = 0
        for i in 1..<(pts.count - 1) {
            let d = distanceToSegment(pts[i], pts[0], pts[pts.count - 1])
            if d > maxD { maxD = d; index = i }
        }
        if maxD > epsilon {
            let left = rdp(Array(pts[0...index]), epsilon: epsilon)
            let right = rdp(Array(pts[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [pts[0], pts[pts.count - 1]]
    }

    private static func isAxisAligned(_ quad: [CGPoint]) -> Bool {
        for i in 0..<quad.count {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            let angle = abs(atan2(b.y - a.y, b.x - a.x))
            let fromAxis = min(angle, abs(angle - .pi / 2), abs(angle - .pi))
            if fromAxis > 0.22 { return false }
        }
        return true
    }
}
