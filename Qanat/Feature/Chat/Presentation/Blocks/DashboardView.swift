import SwiftUI

/// Дашборд: виджеты сеткой ([dashboardRows]) и выводы под ними. [widget] рисует виджет-блок целиком, в карточке;
/// ему же передаём, по сколько плиток с цифрами ставить в ряд, — по ширине его места в сетке ([kpiColumns]).
/// Сетка — по ширине блока, а не экрана: дашборд в ленте уже экрана на поля сообщения.
struct DashboardView<Widget: View>: View {
    let widgets: [DashboardWidget]
    let insights: [String]
    @ViewBuilder let widget: (_ block: ChatBlock, _ kpiColumns: Int) -> Widget

    @State private var width: CGFloat = 0

    // Уже — это телефон: в два столбца графики сжимаются.
    private static var twoColumnsMinWidth: CGFloat { 600 }
    // С этой ширины половине хватает и таблицы в 3–4 столбца, и двух плиток в ряд — раскладка как на сайте.
    private static var pairAllMinWidth: CGFloat { 840 }
    private static var gap: CGFloat { 8 }

    var body: some View {
        let rows = dashboardRows(widgets, twoColumns: width >= Self.twoColumnsMinWidth, pairAll: width >= Self.pairAllMinWidth)
        let fullTiles = kpiColumns(width)
        let halfTiles = kpiColumns((width - Self.gap) / 2)
        VStack(spacing: Self.gap) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                if row.count == 1 {
                    widget(row[0].block, fullTiles)
                } else {
                    // Пара одной высоты: карточки тянутся до более высокой.
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(row.indices, id: \.self) { item in
                            widget(row[item].block, halfTiles).frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !insights.isEmpty { Insights(insights: insights).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new }
        })
    }
}

/// Ряды сетки дашборда по порядку виджетов. По два в ряд — только обычные (не wide) виджеты и только на широком
/// дашборде ([twoColumns]). Таблице и плиткам с цифрами половины узкого планшета мало, поэтому парами их ставим лишь
/// при [pairAll]; до того — только графики, а таблицы и плитки, как и широкие виджеты, на весь ряд.
func dashboardRows(_ widgets: [DashboardWidget], twoColumns: Bool, pairAll: Bool) -> [[DashboardWidget]] {
    var rows: [[DashboardWidget]] = []
    // Виджеты, которые можно ставить парами, подряд — до другого или до конца; их и раскладываем по два.
    var run: [DashboardWidget] = []
    func flush() {
        rows += stride(from: 0, to: run.count, by: 2).map { Array(run[$0..<min($0 + 2, run.count)]) }
        run = []
    }
    for widget in widgets {
        var isChart = false
        if case .chart = widget.block { isChart = true }
        if twoColumns && !widget.wide && (pairAll || isChart) {
            run.append(widget)
        } else {
            flush()
            rows.append([widget])
        }
    }
    flush()
    return rows
}

/// «Выводы»: плашка со значком и списком.
private struct Insights: View {
    let insights: [String]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 13)).foregroundStyle(palette.primary)
                Text(L.t("chat_dashboard_insights")).textStyle(Typography.labelLarge).foregroundStyle(palette.onPrimaryContainer)
            }
            ForEach(insights.indices, id: \.self) { index in
                // Точка-маркер стоит по центру первой строки текста.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(palette.primary).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(insights[index]).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurface)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.primaryContainer, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}
