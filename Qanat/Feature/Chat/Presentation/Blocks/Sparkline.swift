import SwiftUI

/// Мини-график: плавная линия, под ней мягкая заливка, на последнем значении — точка.
/// [points] — непустой результат [sparkPoints]. [drawn] — какая доля графика уже нарисована слева, 0…1.
/// [background] — цвет под графиком: кольцо этого цвета отделяет точку от линии и заливки.
struct Sparkline: View {
    let points: [CGPoint]
    let color: Color
    let background: Color
    var drawn: CGFloat = 1

    private static let lineWidth: CGFloat = 2
    private static let dotRadius: CGFloat = 3
    private static let ringWidth: CGFloat = 2
    // Заливка — лёгкая дымка под линией, а не сплошной цветной блок.
    private static let washAlpha = 0.2

    var body: some View {
        Canvas { context, size in
            let line = Self.lineWidth
            let ring = Self.dotRadius + Self.ringWidth
            // Слева — полтолщины линии под скруглённый конец, справа и по высоте — место под точку с кольцом.
            let plot = points.map {
                CGPoint(x: line / 2 + $0.x * (size.width - line / 2 - ring), y: ring + $0.y * (size.height - 2 * ring))
            }
            guard let first = plot.first, let end = plot.last else { return }
            let curveSegments = sparkSegments(plot)
            var curve = Path()
            curve.move(to: first)
            for segment in curveSegments { curve.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2) }
            var area = curve
            area.addLine(to: CGPoint(x: end.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * drawn, height: size.height)))
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(Self.washAlpha), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: ring), endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: end.x - ring, y: end.y - ring, width: ring * 2, height: ring * 2)), with: .color(background))
            let dot = Self.dotRadius
            context.fill(Path(ellipseIn: CGRect(x: end.x - dot, y: end.y - dot, width: dot * 2, height: dot * 2)), with: .color(color))
        }
    }
}

/// Точки мини-графика в долях области: x — от 0 до 1 слева направо, y — 0 у наибольшего значения (верх),
/// 1 у наименьшего. Все значения равны — линия посередине. Осталось меньше двух чисел — список пуст.
func sparkPoints(_ values: [Double]) -> [CGPoint] {
    let finite = values.filter(\.isFinite)
    guard finite.count >= 2, let low = finite.min(), let high = finite.max() else { return [] }
    let range = high - low
    return finite.enumerated().map { index, value in
        CGPoint(x: CGFloat(index) / CGFloat(finite.count - 1), y: range == 0 ? 0.5 : CGFloat(1 - (value - low) / range))
    }
}

/// Отрезок кривой Безье: от конца предыдущего (или от первой точки) через опорные точки в [end].
struct SparkSegment: Equatable {
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
}

/// Плавная кривая через [points] (x возрастает) — монотонная кубическая, как `type="monotone"` в Recharts:
/// между соседними точками она не выходит за их значения, поэтому ложных пиков и провалов нет.
func sparkSegments(_ points: [CGPoint]) -> [SparkSegment] {
    guard points.count >= 2 else { return [] }
    let slopes = zip(points, points.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
    var tangents = [CGFloat](repeating: 0, count: points.count)
    let last = points.count - 1
    // Наклон в точке — по соседним отрезкам; на вершине и во впадине он нулевой, кривая там плоская.
    if last >= 2 {
        for i in 1..<last {
            let before = points[i].x - points[i - 1].x
            let after = points[i + 1].x - points[i].x
            let s0 = slopes[i - 1]
            let s1 = slopes[i]
            let average = (s0 * after + s1 * before) / (before + after)
            let signs = CGFloat(s0.sign == .minus ? -1 : (s0 == 0 ? 0 : 1)) + CGFloat(s1.sign == .minus ? -1 : (s1 == 0 ? 0 : 1))
            tangents[i] = signs * min(abs(s0), abs(s1), abs(average) / 2)
        }
    }
    // На концах — односторонний наклон; у двух точек кривая — прямая.
    tangents[0] = last == 1 ? slopes[0] : (3 * slopes[0] - tangents[1]) / 2
    tangents[last] = last == 1 ? slopes[0] : (3 * slopes[last - 1] - tangents[last - 1]) / 2
    return (1...last).map { i in
        let from = points[i - 1]
        let to = points[i]
        let third = (to.x - from.x) / 3
        return SparkSegment(
            control1: CGPoint(x: from.x + third, y: from.y + third * tangents[i - 1]),
            control2: CGPoint(x: to.x - third, y: to.y - third * tangents[i]),
            end: to
        )
    }
}
