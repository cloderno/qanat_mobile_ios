import SwiftUI

/// График из ответа агента: столбцы и линии — на Swift Charts, полосы и кольцо — свои.
struct ChartView: View {
    let chart: ChartBlock

    @Environment(\.palette) private var palette

    var body: some View {
        let rows = chart.rows()
        let colors = chartColors(palette)
        // Без единого числа рисовать нечего — у блока остаётся только заголовок.
        if rows.contains(where: { $0.contains { $0 != nil } }) {
            // Кольцо — про доли положительных чисел и не больше категорий, чем различимых цветов; иначе те же числа полосами.
            let donut = chart.kind == .donut && chart.categories.count <= colors.count && rows[0].contains { ($0 ?? 0) > 0 }
            VStack(alignment: .leading, spacing: 10) {
                // У кольца единица — в его центре, у остальных — над графиком, как подпись оси.
                if !donut { UnitCaption(text: chart.unit) }
                if donut {
                    DonutChart(chart: chart, values: rows[0], colors: colors)
                } else if chart.kind == .donut {
                    HorizontalBarChart(chart: ChartBlock(title: chart.title, kind: .bar, categories: chart.categories, series: chart.series, unit: chart.unit, subtitle: chart.subtitle), rows: Array(rows.prefix(1)), colors: colors)
                } else if chart.kind == .bar || chart.kind == .stackedBar {
                    HorizontalBarChart(chart: chart, rows: rows, colors: colors)
                } else {
                    AxisChart(chart: chart, rows: rows, colors: colors)
                }
                // Легенда — и у одного ряда: «факт» или «прогноз» часто только в имени ряда. У кольца цвета — категории,
                // поэтому имя его ряда — просто подписью.
                if donut {
                    if let name = chart.series.first?.name, !name.isEmpty { UnitCaption(text: name) }
                } else {
                    // Кольцо, нарисованное полосами, показывает только первый ряд.
                    let shown = chart.kind == .donut ? Array(chart.series.prefix(1)) : chart.series
                    if shown.contains(where: { !$0.name.isEmpty }) {
                        SeriesLegend(names: shown.map(\.name), colors: colors, lineKeys: chart.kind == .line)
                    }
                }
            }
        }
    }
}

/// Цвета рядов: первым — бирюзовый бренда, дальше оттенки в порядке, где соседние ряды различимы и при дальтонизме.
/// У тёмной темы свои шаги тех же оттенков — под тёмную карточку.
func chartColors(_ palette: Palette) -> [Color] {
    palette.isDark
        ? [0x039E93, 0xDF6C32, 0x4885DF, 0xBF8608, 0xDC6995, 0x278733, 0x8077D6, 0xDA534F].map { Color(hex: $0) }
        : [0x01948A, 0xE76C2B, 0x3475D3, 0xD79706, 0xDC6292, 0x299236, 0x5A49B2, 0xD33A3C].map { Color(hex: $0) }
}

/// Появление: столбцы, полосы и кольцо вырастают с одной скоростью.
let chartAppear = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.7)

/// Прозрачность невыбранных строк и сегментов, когда по одной из них тапнули.
let dimmedAlpha = 0.35

/// Единица измерения над графиком — как подпись оси.
private struct UnitCaption: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        if !text.isEmpty {
            Text(text).textStyle(Typography.labelSmall).foregroundStyle(palette.onSurfaceVariant)
        }
    }
}

/// Легенда рядов: метка повторяет вид отметки — черта у линии, квадратик у столбцов и полос.
private struct SeriesLegend: View {
    let names: [String]
    let colors: [Color]
    let lineKeys: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        FlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(names.indices, id: \.self) { index in
                if !names[index].isEmpty {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: lineKeys ? 2 : 3)
                            .fill(colors[index % colors.count])
                            .frame(width: lineKeys ? 14 : 10, height: lineKeys ? 3 : 10)
                        Text(names[index]).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

/// Элементы в строку с переносом — как FlowRow в Compose.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            maxX = max(maxX, x - horizontalSpacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
