import SwiftUI

/// Горизонтальные полосы: по строке на категорию — название, под ним полоса и число у её конца.
/// У stackedBar полоса из частей рядов и сумма у конца, у bar с несколькими рядами — по полосе на ряд.
/// Полосы вырастают от нуля; тап по строке выделяет её, а у стопки ещё и раскладывает сумму по рядам.
struct HorizontalBarChart: View {
    let chart: ChartBlock
    let rows: [[Double?]]
    let colors: [Color]

    @State private var selected: Int?
    @State private var grow: CGFloat = 0
    @Environment(\.palette) private var palette

    private static let barLine: CGFloat = 18
    private static let barHeight: CGFloat = 12
    private static let lineGap: CGFloat = 4
    private static let tipGap: CGFloat = 6
    private static let seam: CGFloat = 2

    var body: some View {
        let stacked = chart.kind == .stackedBar && rows.count > 1
        let numbers = ChartNumbers()
        let scale = BarScale(valueRange(rows, stacked: stacked))
        let short = numbers.short(largest: scale.largest)
        let bars = categoryBars(stacked: stacked, short: short)
        // Место под числа одно на все строки — справа у положительных, слева у отрицательных, — чтобы масштаб был общий.
        let tips = bars.flatMap(\.tips)
        let room = (
            left: tips.filter { $0.value < 0 }.map(\.width).max() ?? 0,
            right: tips.filter { $0.value >= 0 }.map(\.width).max() ?? 0
        )
        let unit = chart.unit.isEmpty ? "" : " \(chart.unit)"
        VStack(alignment: .leading, spacing: 2) {
            ForEach(chart.categories.indices, id: \.self) { index in
                let lines = stacked ? 1 : rows.count
                Button { withAnimation(.easeInOut(duration: 0.2)) { selected = selected == index ? nil : index } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chart.categories[index])
                            .textStyle(Typography.bodySmall)
                            .foregroundStyle(palette.onSurface)
                            .lineLimit(2)
                        Canvas { context, size in
                            draw(bars[index], scale: scale, room: room, in: &context, size: size)
                        }
                        .frame(height: Self.barLine * CGFloat(lines) + Self.lineGap * CGFloat(lines - 1))
                        .accessibilityLabel(spokenValues(chart, rows: rows, index: index, numbers: numbers) + unit)
                        if stacked && selected == index {
                            breakdown(index, numbers: numbers).transition(.opacity)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .opacity(selected != nil && selected != index ? dimmedAlpha : 1)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { withAnimation(chartAppear) { grow = 1 } }
    }

    private struct Piece {
        let line: Int
        let range: ClosedRange<Double>
        let color: Color
        let outer: Bool
    }

    private struct Tip {
        let line: Int
        let value: Double
        let text: String
        let width: CGFloat
    }

    private struct CategoryBars {
        let pieces: [Piece]
        let tips: [Tip]
    }

    private func categoryBars(stacked: Bool, short: (Double) -> String) -> [CategoryBars] {
        let ends = stackEnds(rows)
        let totals = stackTotals(rows)
        let font = Typography.labelMedium.uiFont.withMonospacedDigits()
        func tip(_ line: Int, _ value: Double) -> Tip {
            let text = short(value)
            return Tip(line: line, value: value, text: text, width: ceil((text as NSString).size(withAttributes: [.font: font]).width))
        }
        return chart.categories.indices.map { index in
            if stacked {
                let pieces = stackSegments(rows.map { $0[index] }).enumerated().compactMap { series, range -> Piece? in
                    guard let range else { return nil }
                    let end = range.lowerBound >= 0 ? ends[index].positive : ends[index].negative
                    return Piece(line: 0, range: range, color: colors[series % colors.count], outer: end == series)
                }
                // У стопки — сумма положительной части справа и отрицательной слева.
                var tips: [Tip] = []
                if totals[index].upperBound > 0 { tips.append(tip(0, totals[index].upperBound)) }
                if totals[index].lowerBound < 0 { tips.append(tip(0, totals[index].lowerBound)) }
                return CategoryBars(pieces: pieces, tips: tips)
            }
            let values = rows.map { $0[index] }
            return CategoryBars(
                pieces: values.enumerated().compactMap { series, value in
                    value.map { Piece(line: series, range: $0 >= 0 ? 0...$0 : $0...0, color: colors[series % colors.count], outer: true) }
                },
                tips: values.enumerated().compactMap { series, value in value.map { tip(series, $0) } }
            )
        }
    }

    /// Полосы одной категории: [grow] — доля роста от нуля при появлении.
    private func draw(_ bars: CategoryBars, scale: BarScale, room: (left: CGFloat, right: CGFloat), in context: inout GraphicsContext, size: CGSize) {
        let start = room.left > 0 ? room.left + Self.tipGap : 0
        let end = size.width - (room.right > 0 ? room.right + Self.tipGap : 0)
        func x(_ value: Double) -> CGFloat { start + scale.fraction(value * Double(grow)) * (end - start) }
        let step = Self.barLine + Self.lineGap
        let radius = Self.barHeight / 2
        for piece in bars.pieces {
            let positive = piece.range.lowerBound >= 0
            var left = x(piece.range.lowerBound)
            var right = x(piece.range.upperBound)
            // Внутренние части стопки отделены от следующей полоской фона.
            if !piece.outer {
                if positive { right -= Self.seam } else { left += Self.seam }
            }
            guard right > left else { continue }
            let top = CGFloat(piece.line) * step + (Self.barLine - Self.barHeight) / 2
            // Скруглён только внешний край, у нуля полоса прямая.
            let roundRight = piece.outer && positive ? radius : 0
            let roundLeft = piece.outer && !positive ? radius : 0
            let rect = CGRect(x: left, y: top, width: right - left, height: Self.barHeight)
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: roundLeft, bottomLeadingRadius: roundLeft,
                bottomTrailingRadius: roundRight, topTrailingRadius: roundRight
            )
            context.fill(shape.path(in: rect), with: .color(piece.color))
        }
        for tip in bars.tips {
            let text = Text(tip.text).font(Typography.labelMedium.font.monospacedDigit()).foregroundColor(palette.onSurface)
            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: size)
            let tx = tip.value < 0 ? x(tip.value) - Self.tipGap - textSize.width : x(tip.value) + Self.tipGap
            let ty = CGFloat(tip.line) * step + (Self.barLine - textSize.height) / 2
            var faded = context
            faded.opacity = Double(grow)
            faded.draw(resolved, at: CGPoint(x: tx, y: ty), anchor: .topLeading)
        }
    }

    /// Раскладка стопки по рядам — показывается под выбранной строкой.
    private func breakdown(_ index: Int, numbers: ChartNumbers) -> some View {
        FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows.indices, id: \.self) { series in
                if let value = rows[series][index] {
                    HStack(spacing: 5) {
                        Circle().fill(colors[series % colors.count]).frame(width: 8, height: 8)
                        let name = chart.series[series].name
                        (Text(name.isEmpty ? "" : "\(name) ").foregroundColor(palette.onSurfaceVariant)
                            + Text(numbers.value(value)).fontWeight(.semibold).foregroundColor(palette.onSurface))
                            .font(Typography.bodySmall.font.monospacedDigit())
                    }
                }
            }
        }
    }
}

extension UIFont {
    /// Цифры одной ширины — как fontFeatureSettings "tnum".
    func withMonospacedDigits() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
