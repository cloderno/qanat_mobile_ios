import SwiftUI

/// Кольцо долей первого ряда по категориям: сегменты с промежутками, в центре — «Всего», сумма и единица,
/// под кольцом — легенда с числами и долями. Тап по сегменту или строке легенды выводит в центр её значение.
struct DonutChart: View {
    let chart: ChartBlock
    let values: [Double?]
    let colors: [Color]

    @State private var selected: Int?
    @State private var sweep: CGFloat = 0
    @Environment(\.palette) private var palette

    private static let donutSize: CGFloat = 180
    private static let segmentGap: CGFloat = 2
    // Доли диаметра: толщина кольца и ширина подписи в центре (с запасом внутри «дырки»).
    private static let ringShare: CGFloat = 0.13
    private static let centerShare: CGFloat = 0.6

    var body: some View {
        let numbers = ChartNumbers()
        let shares = Qanat.shares(values)
        let total = values.reduce(0.0) { $0 + max($1 ?? 0, 0) }
        let short = numbers.short(largest: total)
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, Self.donutSize)
                ZStack {
                    Canvas { context, size in
                        drawRing(shares: shares, in: &context, size: size, width: size.width * Self.ringShare)
                    }
                    .frame(width: side, height: side)
                    .contentShape(Circle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let radius = side / 2
                        let dx = value.location.x - radius
                        let dy = value.location.y - radius
                        let distance = hypot(dx, dy)
                        // Угол от верха по часовой стрелке; тап в середину или мимо кольца снимает выбор.
                        let position = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) / 360
                        let inRing = distance >= radius - side * Self.ringShare && distance <= radius
                        let hit = inRing ? segmentAt(Double(position), shares: shares) : nil
                        withAnimation(.easeInOut(duration: 0.2)) { selected = hit == selected ? nil : hit }
                    })
                    .accessibilityLabel(spokenSummary(chart, rows: [values], numbers: numbers))
                    center(
                        label: selected.map { chart.categories[$0] } ?? L.t("chat_chart_total"),
                        value: short(selected.flatMap { values[$0] } ?? total)
                    )
                    .frame(width: side * Self.centerShare)
                    .id(selected)
                    .transition(.opacity)
                }
                .frame(width: proxy.size.width, height: side)
            }
            .frame(height: Self.donutSize)
            VStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { index in
                    if let value = values[index] {
                        legendRow(index: index, value: numbers.value(value), share: numbers.percent(shares[index]))
                    }
                }
            }
        }
        .onAppear { withAnimation(chartAppear) { sweep = 1 } }
    }

    /// Сегменты разворачиваются по часовой стрелке от верха по мере [sweep].
    private func drawRing(shares: [Double], in context: inout GraphicsContext, size: CGSize, width: CGFloat) {
        let radius = (min(size.width, size.height) - width) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Промежуток одной ширины по дуге — в градусах на средней линии кольца; у единственного сегмента его нет.
        let gap = shares.filter { $0 > 0 }.count > 1 ? Double(Self.segmentGap / radius) * 180 / .pi : 0
        let shown = 360 * Double(sweep)
        var start = 0.0
        for (index, share) in shares.enumerated() {
            let segment = share * 360
            let visible = min(max(shown - start, 0), segment) - gap
            if visible > 0 {
                var path = Path()
                path.addArc(
                    center: center, radius: radius,
                    startAngle: .degrees(start - 90 + gap / 2), endAngle: .degrees(start - 90 + gap / 2 + visible),
                    clockwise: false
                )
                var layer = context
                layer.opacity = selected == nil || selected == index ? 1 : dimmedAlpha
                layer.stroke(path, with: .color(colors[index % colors.count]), lineWidth: width)
            }
            start += segment
        }
    }

    private func center(label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(label).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            Text(value)
                .textStyle(value.count <= 7 ? Typography.titleLarge : Typography.titleMedium)
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !chart.unit.isEmpty {
                Text(chart.unit).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            }
        }
    }

    private func legendRow(index: Int, value: String, share: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { selected = selected == index ? nil : index } } label: {
            HStack(spacing: 8) {
                Circle().fill(colors[index % colors.count]).frame(width: 10, height: 10)
                // Не обрезаем: хвост подписи бывает «факт» или «прогноз».
                Text(chart.categories[index])
                    .textStyle(Typography.bodySmall)
                    .foregroundStyle(palette.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(value).font(Typography.bodySmall.weight(.semibold).font.monospacedDigit()).foregroundStyle(palette.onSurface)
                Text(share)
                    .font(Typography.bodySmall.font.monospacedDigit())
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(selected != nil && selected != index ? dimmedAlpha : 1)
        }
        .buttonStyle(.plain)
    }
}
