import SwiftUI

/// Таблица ответа — и в ленте, и виджетом дашборда. Ширина столбцов — по содержимому ([tableColumns]), слова
/// не рвутся. Не помещается — листается вбок внутри карточки, первый столбец стоит на месте ([pinFirstColumn]),
/// справа — мягкое затухание. На узкой карточке таблица из многих столбцов — карточками по строке ([tableAsCards]).
struct DataTable: View {
    let columns: [String]
    let rows: [[String]]

    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if width == 0 {
                Color.clear.frame(height: 1)
            } else if tableAsCards(columnCount: tableColumnCount(header: columns, rows: rows), width: width) {
                RowCards(header: columns, rows: rows)
            } else {
                TableGrid(header: columns, rows: rows, available: width)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new }
        })
    }
}

private let cellPadding: CGFloat = 6
private let cellPaddingVertical: CGFloat = 6
private let fadeWidth: CGFloat = 28
/// Запас к замеренной ширине: разбивке строк бывает мало ровно замеренной ширины — и слово рвётся на букву.
private let textSafety: CGFloat = 1

private struct TableGrid: View {
    let header: [String]
    let rows: [[String]]
    let available: CGFloat

    @State private var offset: CGFloat = 0
    @Environment(\.palette) private var palette

    private var headerFont: UIFont { Typography.labelSmall.weight(.medium).uiFont }
    private var cellFont: UIFont { Typography.bodySmall.uiFont }
    private var numberFont: UIFont { cellFont.withMonospacedDigits() }

    var body: some View {
        let specs = tableColumns(
            header: header,
            rows: rows,
            available: available,
            cellPadding: cellPadding * 2,
            measureHeader: { measure($0, headerFont) },
            measureCell: { measure($0, isNumericCell($0) ? numberFont : cellFont) }
        )
        let pinned = pinFirstColumn(specs, available: available)
        // Высота строки — по самой высокой ячейке: ширины столбцов известны, поэтому считаем её заранее —
        // так закреплённый столбец и листаемые идут ровно строка в строку.
        let heights = [lineHeight(header, specs: specs, isHeader: true)] + rows.map { lineHeight($0, specs: specs, isHeader: false) }
        let scrolledSpecs = Array(specs.dropFirst(pinned ? 1 : 0))
        let visible = available - (pinned ? specs[0].width : 0)
        let content = scrolledSpecs.reduce(0) { $0 + $1.width }
        let scrollable = content > visible + 0.5
        HStack(alignment: .top, spacing: 0) {
            if pinned {
                column(0, spec: specs[0], heights: heights)
                    .overlay(alignment: .trailing) {
                        // Пролистали — у закреплённого столбца появляется граница: видно, что под ним уходят ячейки.
                        if offset < -0.5 { Rectangle().fill(palette.outlineVariant).frame(width: 1) }
                    }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach((pinned ? 1 : 0)..<specs.count, id: \.self) { index in
                        column(index, spec: specs[index], heights: heights)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: proxy.frame(in: .named("table")).minX)
                })
            }
            .coordinateSpace(name: "table")
            .scrollDisabled(!scrollable)
            .onPreferenceChange(ScrollOffsetKey.self) { offset = $0 }
        }
        .overlay(alignment: .trailing) {
            // Затухание у правого края: справа ещё есть столбцы.
            if scrollable && -offset < content - visible - 1 {
                LinearGradient(colors: [palette.surfaceContainer.opacity(0), palette.surfaceContainer], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Столбец таблицы: шапка и ячейки, каждая — высотой своей строки.
    private func column(_ index: Int, spec: TableColumn, heights: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cell(index < header.count ? header[index] : "", index: index, spec: spec, isHeader: true, height: heights[0])
            ForEach(rows.indices, id: \.self) { row in
                Rectangle().fill(palette.outlineVariant).frame(height: 1)
                cell(index < rows[row].count ? rows[row][index] : "", index: index, spec: spec, isHeader: false, height: heights[row + 1])
            }
        }
    }

    // У края карточки поле не нужно: ширину столбец считал с ним — первый отдаёт его правому полю.
    private func cell(_ text: String, index: Int, spec: TableColumn, isHeader: Bool, height: CGFloat) -> some View {
        let number = !isHeader && isNumericCell(text)
        let alignment: Alignment = number || spec.numeric ? .topTrailing : .topLeading
        return Text(text)
            .font(isHeader ? Typography.labelSmall.weight(.medium).font : (number ? Typography.bodySmall.font.monospacedDigit() : Typography.bodySmall.font))
            .foregroundStyle(isHeader ? palette.onSurfaceVariant : palette.onSurface)
            // Число не переносится: ширина столбца уже вмещает его целиком.
            .lineLimit(number ? 1 : nil)
            .multilineTextAlignment(number || spec.numeric ? .trailing : .leading)
            .frame(width: textWidth(spec), height: height, alignment: alignment)
            .padding(.leading, index == 0 ? 0 : cellPadding)
            .padding(.trailing, index == 0 ? cellPadding * 2 : cellPadding)
            .padding(.vertical, cellPaddingVertical)
    }

    private func textWidth(_ spec: TableColumn) -> CGFloat { max(spec.width - cellPadding * 2, 1) }

    /// Высота текста строки — по самой высокой ячейке при ширине её столбца.
    private func lineHeight(_ cells: [String], specs: [TableColumn], isHeader: Bool) -> CGFloat {
        specs.indices.map { index -> CGFloat in
            let text = index < cells.count ? cells[index] : ""
            let font = isHeader ? headerFont : (isNumericCell(text) ? numberFont : cellFont)
            let rect = ((text.isEmpty ? " " : text) as NSString).boundingRect(
                with: CGSize(width: textWidth(specs[index]), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return ceil(rect.height)
        }.max() ?? 0
    }

    private func measure(_ text: String, _ font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + textSafety
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Таблица карточками: заголовок — первая ячейка, ниже пары «столбец: значение» через точку.
private struct RowCards: View {
    let header: [String]
    let rows: [[String]]

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.first ?? "").textStyle(Typography.bodyMedium.weight(.semibold)).foregroundStyle(palette.onSurface)
                    let details = rowDetails(row)
                    if !details.isEmpty { details.reduce(Text(""), +).font(Typography.bodySmall.font) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// «Просрочено: 4 · Всего: 12» — пары «столбец: значение» без пустых значений.
    private func rowDetails(_ row: [String]) -> [Text] {
        let count = tableColumnCount(header: header, rows: [row])
        let pairs: [(String, String)] = (1..<max(count, 1)).compactMap { index in
            let value = (index < row.count ? row[index] : "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return ((index < header.count ? header[index] : "").trimmingCharacters(in: .whitespaces), value)
        }
        var parts: [Text] = []
        for (position, (title, value)) in pairs.enumerated() {
            if position > 0 { parts.append(Text(" · ").foregroundColor(palette.onSurfaceVariant)) }
            // Название столбца не отрывается от значения, а число — от своих разрядов.
            if !title.isEmpty { parts.append(Text("\(title):\u{00A0}").foregroundColor(palette.onSurfaceVariant)) }
            let shown = isNumericCell(value) ? value.replacingOccurrences(of: " ", with: "\u{00A0}") : value
            parts.append(Text(shown).fontWeight(.semibold).monospacedDigit().foregroundColor(palette.onSurface))
        }
        return parts
    }
}
