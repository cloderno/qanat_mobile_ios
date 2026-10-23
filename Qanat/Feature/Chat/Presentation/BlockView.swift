import SwiftUI

/// Блок из ответа агента: карточки с цифрами, таблица, график, дашборд, презентация, письмо.
/// Карточка у всех блоков одна — и в ленте, и виджетом дашборда: те же поля, скругление и рамка.
struct BlockView: View {
    let block: ChatBlock
    let actions: MessageActions
    /// По сколько плиток с цифрами в ряд, если решает дашборд; nil — по ширине самой карточки.
    var kpiColumns: Int?

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Заголовок и строка под ним не обрезаются — переносятся: в них «факт» или «прогноз» и период.
            if !block.title.isEmpty || !block.subtitle.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !block.title.isEmpty {
                        Text(block.title).textStyle(Typography.bodySmall.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant)
                    }
                    if !block.subtitle.isEmpty {
                        Text(block.subtitle).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.outline, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .kpis(_, let items, _):
            KpiCards(items: items, columns: kpiColumns)
        case .table(_, let columns, let rows, _):
            DataTable(columns: columns, rows: rows)
        case .chart(let chart):
            ChartView(chart: chart)
        case .dashboard(_, let widgets, let insights, _):
            DashboardView(widgets: widgets, insights: insights) { widget, tiles in
                BlockView(block: widget, actions: actions, kpiColumns: tiles)
            }
        case .deck(let title, let url):
            DeckView(title: title, url: url)
        case .letter(let letter):
            LetterView(
                letter: letter,
                downloading: letter.documentId != nil && letter.documentId == actions.downloadingDocument,
                onDownload: { if let id = letter.documentId { actions.onDownloadDocument(id) } },
                onSaveTemplate: { name in if let id = letter.documentId { actions.onSaveTemplate(id, name) } }
            )
        case .unsupported:
            Text(L.t("chat_block_unsupported")).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
        }
    }
}
