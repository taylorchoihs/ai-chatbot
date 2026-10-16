import UIKit
import PencilKit

/// 편집 가능한 도형 (PencilKit 획으로 만들어지므로 올가미로 이동·크기·색 변경 가능)
enum ShapeKind: String, CaseIterable, Identifiable {
    case line, dashedLine, arrow, doubleArrow
    case rectangle, roundedRect, square, circle, ellipse, semicircle
    case triangle, rightTriangle, diamond, parallelogram, trapezoid
    case pentagon, hexagon, octagon, star, plus, heart
    case check, xMark, speechBubble
    case cylinder, cube, cone
    case axes, numberLine, sineWave, parabola, table, circleRadius, angle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "직선"
        case .dashedLine: return "점선"
        case .arrow: return "화살표"
        case .doubleArrow: return "양방향 화살표"
        case .rectangle: return "직사각형"
        case .roundedRect: return "둥근 사각형"
        case .square: return "정사각형"
        case .circle: return "원"
        case .ellipse: return "타원"
        case .semicircle: return "반원"
        case .triangle: return "삼각형"
        case .rightTriangle: return "직각삼각형"
        case .diamond: return "마름모"
        case .parallelogram: return "평행사변형"
        case .trapezoid: return "사다리꼴"
        case .pentagon: return "오각형"
        case .hexagon: return "육각형"
        case .octagon: return "팔각형"
        case .star: return "별"
        case .plus: return "십자"
        case .heart: return "하트"
        case .check: return "체크"
        case .xMark: return "엑스"
        case .speechBubble: return "말풍선"
        case .cylinder: return "원기둥"
        case .cube: return "정육면체"
        case .cone: return "원뿔"
        case .axes: return "좌표축"
        case .numberLine: return "수직선"
        case .sineWave: return "사인 곡선"
        case .parabola: return "포물선"
        case .table: return "표 3×3"
        case .circleRadius: return "원과 반지름"
        case .angle: return "각"
        }
    }

    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .dashedLine: return "line.3.horizontal"
        case .arrow: return "arrow.right"
        case .doubleArrow: return "arrow.left.and.right"
        case .rectangle: return "rectangle"
        case .roundedRect: return "app"
        case .square: return "square"
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .semicircle: return "circle.bottomhalf.filled"
        case .triangle: return "triangle"
        case .rightTriangle: return "triangle.lefthalf.filled"
        case .diamond: return "diamond"
        case .parallelogram: return "rectangle.portrait.and.arrow.right"
        case .trapezoid: return "trapezoid.and.line.horizontal"
        case .pentagon: return "pentagon"
        case .hexagon: return "hexagon"
        case .octagon: return "octagon"
        case .star: return "star"
        case .plus: return "plus"
        case .heart: return "heart"
        case .check: return "checkmark"
        case .xMark: return "xmark"
        case .speechBubble: return "bubble.left"
        case .cylinder: return "cylinder"
        case .cube: return "cube"
        case .cone: return "cone"
        case .axes: return "chart.xyaxis.line"
        case .numberLine: return "ruler"
        case .sineWave: return "waveform.path"
        case .parabola: return "point.topleft.down.to.point.bottomright.curvepath"
        case .table: return "tablecells"
        case .circleRadius: return "circle.circle"
        case .angle: return "angle"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .line, .dashedLine, .arrow, .doubleArrow, .numberLine: return CGSize(width: 220, height: 40)
        case .rectangle, .roundedRect, .parallelogram, .trapezoid, .speechBubble: return CGSize(width: 200, height: 130)
        case .ellipse: return CGSize(width: 200, height: 120)
        case .semicircle: return CGSize(width: 180, height: 90)
        case .sineWave: return CGSize(width: 240, height: 90)
        case .table: return CGSize(width: 240, height: 150)
        case .axes, .parabola: return CGSize(width: 200, height: 200)
        default: return CGSize(width: 150, height: 150)
        }
    }

    /// 단위 정사각형(0...1) 좌표의 폴리라인 목록
    var unitPaths: [[CGPoint]] {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func closed(_ pts: [CGPoint]) -> [CGPoint] { pts + [pts[0]] }
        func ellipse(cx: CGFloat = 0.5, cy: CGFloat = 0.5, rx: CGFloat = 0.5, ry: CGFloat = 0.5,
                     from a0: CGFloat = 0, to a1: CGFloat = 2 * .pi, steps: Int = 72) -> [CGPoint] {
            (0...steps).map { i in
                let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
                return p(cx + rx * cos(a), cy + ry * sin(a))
            }
        }
        func polygon(_ n: Int, rotation: CGFloat = -.pi / 2) -> [CGPoint] {
            closed((0..<n).map { i in
                let a = rotation + 2 * .pi * CGFloat(i) / CGFloat(n)
                return p(0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a))
            })
        }
        switch self {
        case .line: return [[p(0, 0.5), p(1, 0.5)]]
        case .dashedLine:
            return stride(from: 0.0, to: 1.0, by: 0.08).map { x in [p(x, 0.5), p(min(1, x + 0.05), 0.5)] }
        case .arrow: return [[p(0, 0.5), p(1, 0.5)], [p(0.88, 0.2), p(1, 0.5), p(0.88, 0.8)]]
        case .doubleArrow:
            return [[p(0, 0.5), p(1, 0.5)], [p(0.88, 0.2), p(1, 0.5), p(0.88, 0.8)], [p(0.12, 0.2), p(0, 0.5), p(0.12, 0.8)]]
        case .rectangle, .square: return [closed([p(0, 0), p(1, 0), p(1, 1), p(0, 1)])]
        case .roundedRect:
            let r: CGFloat = 0.15
            var pts: [CGPoint] = []
            pts += ellipse(cx: 1 - r, cy: r, rx: r, ry: r, from: -.pi / 2, to: 0, steps: 10)
            pts += ellipse(cx: 1 - r, cy: 1 - r, rx: r, ry: r, from: 0, to: .pi / 2, steps: 10)
            pts += ellipse(cx: r, cy: 1 - r, rx: r, ry: r, from: .pi / 2, to: .pi, steps: 10)
            pts += ellipse(cx: r, cy: r, rx: r, ry: r, from: .pi, to: 1.5 * .pi, steps: 10)
            return [closed(pts)]
        case .circle, .ellipse: return [ellipse()]
        case .semicircle:
            return [ellipse(cx: 0.5, cy: 1, rx: 0.5, ry: 1, from: .pi, to: 2 * .pi, steps: 48) + [p(0, 1)]]
        case .triangle: return [closed([p(0.5, 0), p(1, 1), p(0, 1)])]
        case .rightTriangle: return [closed([p(0, 0), p(1, 1), p(0, 1)]), [p(0, 0.88), p(0.12, 0.88), p(0.12, 1)]]
        case .diamond: return [closed([p(0.5, 0), p(1, 0.5), p(0.5, 1), p(0, 0.5)])]
        case .parallelogram: return [closed([p(0.25, 0), p(1, 0), p(0.75, 1), p(0, 1)])]
        case .trapezoid: return [closed([p(0.25, 0), p(0.75, 0), p(1, 1), p(0, 1)])]
        case .pentagon: return [polygon(5)]
        case .hexagon: return [polygon(6, rotation: 0)]
        case .octagon: return [polygon(8, rotation: .pi / 8)]
        case .star:
            return [closed((0..<10).map { i in
                let a = -.pi / 2 + .pi * CGFloat(i) / 5
                let r: CGFloat = i % 2 == 0 ? 0.5 : 0.2
                return p(0.5 + r * cos(a), 0.5 + r * sin(a))
            })]
        case .plus:
            let a: CGFloat = 0.35, b: CGFloat = 0.65
            return [closed([p(a, 0), p(b, 0), p(b, a), p(1, a), p(1, b), p(b, b), p(b, 1), p(a, 1), p(a, b), p(0, b), p(0, a), p(a, a)])]
        case .heart:
            let raw = (0...80).map { i -> CGPoint in
                let t = 2 * CGFloat.pi * CGFloat(i) / 80
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return p(x, -y)
            }
            return [normalize(raw)]
        case .check: return [[p(0, 0.55), p(0.35, 0.9), p(1, 0.1)]]
        case .xMark: return [[p(0, 0), p(1, 1)], [p(1, 0), p(0, 1)]]
        case .speechBubble:
            return [closed([p(0, 0), p(1, 0), p(1, 0.75), p(0.4, 0.75), p(0.2, 1), p(0.25, 0.75), p(0, 0.75)])]
        case .cylinder:
            return [ellipse(cx: 0.5, cy: 0.12, rx: 0.5, ry: 0.12), [p(0, 0.12), p(0, 0.88)], [p(1, 0.12), p(1, 0.88)],
                    ellipse(cx: 0.5, cy: 0.88, rx: 0.5, ry: 0.12, from: 0, to: .pi, steps: 36)]
        case .cube:
            let d: CGFloat = 0.28
            return [closed([p(0, d), p(1 - d, d), p(1 - d, 1), p(0, 1)]),
                    [p(0, d), p(d, 0), p(1, 0), p(1, 1 - d), p(1 - d, 1)],
                    [p(1 - d, d), p(1, 0)]]
        case .cone:
            return [[p(0, 0.86), p(0.5, 0), p(1, 0.86)], ellipse(cx: 0.5, cy: 0.86, rx: 0.5, ry: 0.14)]
        case .axes:
            return [[p(0, 0.5), p(1, 0.5)], [p(0.94, 0.46), p(1, 0.5), p(0.94, 0.54)],
                    [p(0.5, 1), p(0.5, 0)], [p(0.46, 0.06), p(0.5, 0), p(0.54, 0.06)]]
        case .numberLine:
            var paths: [[CGPoint]] = [[p(0, 0.5), p(1, 0.5)], [p(0.95, 0.25), p(1, 0.5), p(0.95, 0.75)],
                                      [p(0.05, 0.25), p(0, 0.5), p(0.05, 0.75)]]
            for i in 1...9 { let x = CGFloat(i) / 10; paths.append([p(x, 0.3), p(x, 0.7)]) }
            return paths
        case .sineWave:
            return [(0...96).map { i in
                let x = CGFloat(i) / 96
                return p(x, 0.5 - 0.5 * sin(x * 4 * .pi))
            }]
        case .parabola:
            return [(0...60).map { i in
                let x = CGFloat(i) / 60
                let u = x * 2 - 1
                return p(x, 1 - (1 - u * u))
            }]
        case .table:
            var paths: [[CGPoint]] = [closed([p(0, 0), p(1, 0), p(1, 1), p(0, 1)])]
            for i in 1...2 {
                let t = CGFloat(i) / 3
                paths.append([p(t, 0), p(t, 1)])
                paths.append([p(0, t), p(1, t)])
            }
            return paths
        case .circleRadius:
            return [ellipse(), [p(0.5, 0.5), p(1, 0.5)], ellipse(cx: 0.5, cy: 0.5, rx: 0.012, ry: 0.012, steps: 12)]
        case .angle:
            return [[p(1, 0.1), p(0, 1), p(1, 1)], ellipse(cx: 0, cy: 1, rx: 0.25, ry: 0.25, from: -0.73, to: 0, steps: 16)]
        }
    }

    private func normalize(_ pts: [CGPoint]) -> [CGPoint] {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        return pts.map { CGPoint(x: ($0.x - minX) / max(maxX - minX, 0.001), y: ($0.y - minY) / max(maxY - minY, 0.001)) }
    }
}

enum ShapeFactory {
    static func strokes(kind: ShapeKind, in rect: CGRect, ink: PKInk, width: CGFloat) -> [PKStroke] {
        let date = Date()
        return kind.unitPaths.compactMap { unit in
            let pts = unit.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            return stroke(points: pts, ink: ink, width: width, date: date)
        }
    }

    /// 폴리라인을 PencilKit 획으로. 꼭짓점을 여러 번 넣어서 B-스플라인이 모서리를 둥글게 만들지 않게 한다.
    static func stroke(points: [CGPoint], ink: PKInk, width: CGFloat, date: Date) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        var controls: [PKStrokePoint] = []
        var t: TimeInterval = 0
        let size = CGSize(width: width, height: width)
        func add(_ p: CGPoint) {
            controls.append(PKStrokePoint(location: p, timeOffset: t, size: size, opacity: 1, force: 1,
                                          azimuth: 0, altitude: .pi / 2))
            t += 0.002
        }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            add(a); add(a); add(a)
            let len = hypot(b.x - a.x, b.y - a.y)
            let steps = Int(len / 6)
            if steps > 1 {
                for s in 1..<steps {
                    let f = CGFloat(s) / CGFloat(steps)
                    add(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                }
            }
        }
        let last = points[points.count - 1]
        add(last); add(last); add(last)
        let path = PKStrokePath(controlPoints: controls, creationDate: date)
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }
}
