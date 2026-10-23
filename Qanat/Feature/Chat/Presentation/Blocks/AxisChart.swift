import Charts
import SwiftUI

/// Столбцы, стопки, линия и область на Swift Charts: круглые деления оси, подписи категорий, числа над столбцами,
/// если помещаются, и подсказка по тапу. Не влезают категории — столбцы листаются вбок, линия сжимается.
struct AxisChart: View {
    let chart: ChartBlock
    let rows: [[Double?]]
    let colors: [Color]

    @State private var selected: String?
    @State private var appeared = false
    @Environment(\.palette) private var palette

    private static let chartHeight: CGFloat = 220
    private static let lineWidth: CGFloat = 2.5
    private static let dotSize: CGFloat = 8
    private static let corner: CGFloat = 6
    private static let maxDots = 14

    private var lines: Bool { chart.kind == .line || chart.kind == .area }
    private var stacked: Bool { chart.kind == .stackedColumn }

    /// Точка графика: категория по номеру (названия категорий могут повторяться), ряд и кусок ряда без пропусков.
    private struct Point: Identifiable {
        let id: String
        let category: String
        let series: Int
        let part: Int
        let value: Double
        let outer: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            plot(width: proxy.size.width)
        }
        .frame(height: Self.chartHeight)
        .onAppear { withAnimation(chartAppear) { appeared = true } }
    }

    private func plot(width: CGFloat) -> some View {
        let numbers = ChartNumbers()
        let ticks = axisTicks(valueRange(rows, stacked: stacked))
        let short = numbers.short(largest: ticks.map(abs).max() ?? 1)
        let labelFont = Typography.labelSmall.uiFont.withMonospacedDigits()
        // Подписи оси значений считаем сами, поэтому её ширина известна заранее; остальное — под категории.
        let axisWidth = (ticks.map { measure(short($0), labelFont) }.max() ?? 0) + 6
        let groupSize = stacked ? 1 : rows.count
        let layout = columnLayout(plotWidth: width - axisWidth, categories: chart.categories.count, groupSize: groupSize)
        let scrolls = !lines && layout.scrolls
        let points = makePoints()
        let labelsFit = !lines && dataLabelsFit(layout: layout, groupSize: groupSize, short: short, font: labelFont)
        let domain = (ticks.first ?? 0)...(ticks.last ?? 1)

        return Chart {
            ForEach(points) { point in
                let color = colors[point.series % colors.count]
                let value = appeared ? point.value : 0
                if lines {
                    if chart.kind == .area {
                        AreaMark(
                            x: .value("category", point.category),
                            y: .value("value", value),
                            series: .value("part", "\(point.series)-\(point.part)")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(
                            colors: [color.opacity(rows.count > 1 ? 0.16 : 0.28), color.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    }
                    LineMark(
                        x: .value("category", point.category),
                        y: .value("value", value),
                        series: .value("part", "\(point.series)-\(point.part)")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .foregroundStyle(color)
                    // Точки — на линии, пока их немного; одиночное значение между пропусками — всегда точка.
                    if point.outer || (chart.kind == .line && chart.categories.count <= Self.maxDots) {
                        PointMark(x: .value("category", point.category), y: .value("value", value))
                            .symbolSize(Self.dotSize * Self.dotSize)
                            .foregroundStyle(color)
                    }
                } else {
                    let bar = BarMark(
                        x: .value("category", point.category),
                        y: .value("value", value),
                        width: .fixed(layout.thickness)
                    )
                    .foregroundStyle(color)
                    .clipShape(barShape(positive: point.value >= 0, rounded: point.outer))
                    if stacked {
                        bar
                    } else {
                        bar
                            .position(by: .value("series", point.series), axis: .horizontal, span: .fixed(layout.groupWidth(groupSize)))
                            .annotation(position: point.value >= 0 ? .top : .bottom, spacing: 2) {
                                if labelsFit && point.value != 0 { dataLabel(short(point.value)) }
                            }
                    }
                }
            }
            if stacked && labelsFit {
                ForEach(Array(stackTotals(rows).enumerated()), id: \.offset) { index, total in
                    if total.upperBound > 0 {
                        PointMark(x: .value("category", categoryId(index)), y: .value("value", appeared ? total.upperBound : 0))
                            .opacity(0)
                            .annotation(position: .top, spacing: 2) { dataLabel(short(total.upperBound)) }
                    }
                }
            }
            if let selected {
                if lines {
                    RuleMark(x: .value("category", selected))
                        .foregroundStyle(palette.onSurfaceVariant.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(Int(selected) ?? 0, numbers: numbers)
                        }
                } else {
                    // Полоса во всю категорию под столбцами — подсветка выбранной.
                    RuleMark(x: .value("category", selected))
                        .foregroundStyle(palette.onSurface.opacity(0.06))
                        .lineStyle(StrokeStyle(lineWidth: layout.slot))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(Int(selected) ?? 0, numbers: numbers)
                        }
                }
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: chart.categories.indices.map(categoryId))
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(palette.outlineVariant)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(short(number)).font(Typography.labelSmall.font.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: chart.categories.indices.map(categoryId)) { value in
                AxisValueLabel(collisionResolution: scrolls ? .disabled : .greedy) {
                    if let id = value.as(String.self), let index = Int(id) {
                        // Пустую подпись — тире.
                        let name = chart.categories[index].trimmingCharacters(in: .whitespaces)
                        Text(name.isEmpty ? "–" : name)
                            .font(Typography.labelSmall.font)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(scrolls ? 2 : 1)
                            .frame(maxWidth: scrolls ? layout.slot : nil)
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .modifier(ScrollIfNeeded(scrolls: scrolls, visible: Int(((width - axisWidth) / layout.slot).rounded(.down))))
        .accessibilityElement()
        .accessibilityLabel(spokenSummary(chart, rows: rows, numbers: numbers))
    }

    private func categoryId(_ index: Int) -> String { String(index) }

    private func makePoints() -> [Point] {
        let ends = stacked ? stackEnds(rows) : []
        var result: [Point] = []
        for (series, row) in rows.enumerated() {
            if lines {
                // Линия рвётся на пропусках: каждый непрерывный кусок — отдельная линия цвета своего ряда.
                for (part, piece) in segments(row).enumerated() {
                    for item in piece {
                        result.append(Point(id: "\(series)-\(item.index)", category: categoryId(item.index), series: series, part: part, value: item.value, outer: piece.count == 1))
                    }
                }
            } else {
                for (index, value) in row.enumerated() {
                    // У столбца пропуск — нулевая высота.
                    let number = value ?? 0
                    let outer = stacked ? (number >= 0 ? ends[index].positive : ends[index].negative) == series : true
                    result.append(Point(id: "\(series)-\(index)", category: categoryId(index), series: series, part: 0, value: number, outer: outer))
                }
            }
        }
        return result
    }

    /// Скругление только у внешнего края столбца: сверху у положительных, снизу у отрицательных.
    private func barShape(positive: Bool, rounded: Bool) -> UnevenRoundedRectangle {
        let r = rounded ? Self.corner : 0
        return positive
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: r)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: 0)
    }

    /// Числа над столбцами — только если самое широкое помещается над своим столбцом целиком.
    private func dataLabelsFit(layout: ColumnLayout, groupSize: Int, short: (Double) -> String, font: UIFont) -> Bool {
        let values = stacked ? stackTotals(rows).flatMap { [$0.lowerBound, $0.upperBound] } : rows.flatMap { $0 }.compactMap { $0 }
        let widest = Set(values.filter { $0 != 0 }.map(short)).map { measure($0, font) }.max() ?? 0
        let room = groupSize == 1 ? layout.slot - 4 : layout.thickness + ColumnLayout.groupGap / 2
        return widest + 6 <= room
    }

    private func dataLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.labelSmall.font.monospacedDigit())
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 4))
            .opacity(appeared ? 1 : 0)
    }

    /// Подсказка по тапу: категория и значения рядов с единицей; у стопки — ещё и сумма.
    private func tooltip(_ index: Int, numbers: ChartNumbers) -> some View {
        // Неразрывный пробел — единица не отрывается от числа при переносе.
        let unit = chart.unit.isEmpty ? "" : "\u{00A0}\(chart.unit)"
        let many = rows.count > 1
        return VStack(alignment: .leading, spacing: 2) {
            Text(index < chart.categories.count ? chart.categories[index] : "").foregroundStyle(palette.onSurfaceVariant)
            ForEach(rows.indices, id: \.self) { series in
                if index < rows[series].count, let value = rows[series][index] {
                    HStack(spacing: 4) {
                        if many { Text("●").foregroundStyle(colors[series % colors.count]) }
                        Text(numbers.value(value) + unit).fontWeight(.semibold).foregroundStyle(palette.onSurface)
                        let name = chart.series[series].name
                        if many && !name.isEmpty { Text(name).foregroundStyle(palette.onSurfaceVariant) }
                    }
                }
            }
            if stacked && many {
                HStack(spacing: 4) {
                    Text(L.t("chat_chart_total")).foregroundStyle(palette.onSurfaceVariant)
                    Text(numbers.value(rows.reduce(0) { $0 + (index < $1.count ? $1[index] ?? 0 : 0) }) + unit)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.onSurface)
                }
            }
        }
        .font(Typography.bodySmall.font.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.outline, lineWidth: 1))
    }

    private func measure(_ text: String, _ font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Тесные столбцы листаются вбок: видно столько категорий, сколько помещается с запасом под их названия.
private struct ScrollIfNeeded: ViewModifier {
    let scrolls: Bool
    let visible: Int

    func body(content: Content) -> some View {
        if scrolls {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(visible, 1))
        } else {
            content
        }
    }
}
