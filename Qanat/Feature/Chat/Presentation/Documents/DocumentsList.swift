import SwiftUI

/// Значок вида документа — в списке «Документов» и на экране документа. Подложка нейтральная:
/// тил в меню означает только открытый чат.
struct DocumentKindIcon: View {
    let kind: AgentDocument.Kind
    var size: CGFloat = 32
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: size * 0.45))
            .foregroundStyle(palette.onSurfaceVariant)
            .frame(width: size, height: size)
            .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

extension AgentDocument.Kind {
    var icon: String {
        switch self {
        case .deck: "rectangle.on.rectangle.angled"
        case .dashboard: "square.grid.2x2"
        case .letter: "envelope"
        case .other: "doc.text"
        }
    }

    /// «Презентация», «Дашборд», «Письмо» — шапка экрана документа и название документа без названия.
    var label: String {
        switch self {
        case .deck: L.t("documents_kind_deck")
        case .dashboard: L.t("documents_kind_dashboard")
        case .letter: L.t("documents_kind_letter")
        case .other: L.t("documents_kind_other")
        }
    }
}

/// Пусто или ошибка: значок, текст и «Повторить», если [onRetry] есть.
struct DocumentsNotice: View {
    let icon: String
    let text: String
    var onRetry: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(palette.onSurfaceVariant)
            Text(text).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
            if let onRetry {
                TextLinkButton(text: L.t("common_retry"), color: palette.tones.link, action: onRetry)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Вкладка «Документы» в меню чатов: фильтр по виду и список — новые сверху, следующие пачки — при прокрутке
/// до конца. Последний фильтр — «Шаблоны писем»: вместо документов показывается [templates].
struct DocumentsList<Templates: View>: View {
    let viewModel: DocumentsViewModel
    let onOpenDocument: (String) -> Void
    @ViewBuilder let templates: () -> Templates
    let onShowTemplates: () -> Void

    // «Шаблоны писем» — не вид документа, а свой список рядом: выбор между ними — дело только этой вкладки.
    @State private var showTemplates = false
    @Environment(\.palette) private var palette

    /// Фильтры по виду; nil — «Все». Неизвестного приложению вида здесь нет: сервер такие не отбирает.
    private static var kinds: [AgentDocument.Kind?] { [nil, .deck, .dashboard, .letter] }

    var body: some View {
        VStack(spacing: 0) {
            // В меню узко, а «Презентации» длинные — фильтры прокручиваются вбок.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(Self.kinds, id: \.self) { kind in
                        FilterChip(label: filterLabel(kind), selected: !showTemplates && kind == viewModel.kind) {
                            showTemplates = false
                            viewModel.selectKind(kind)
                        }
                    }
                    FilterChip(label: L.t("letter_templates_filter"), selected: showTemplates) {
                        if !showTemplates {
                            showTemplates = true
                            onShowTemplates()
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xs)
            }
            if showTemplates {
                templates()
            } else {
                list
            }
        }
        .snackbar(message: viewModel.errorKey.map { L.t($0) }) { viewModel.errorKey = nil }
    }

    @ViewBuilder
    private var list: some View {
        switch viewModel.list {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let key):
            refreshable {
                DocumentsNotice(icon: "exclamationmark.circle", text: L.t(key), onRetry: viewModel.retry).listRowStyle()
            }
        case .loaded(let documents, let nextPage, let filtered):
            refreshable {
                if documents.isEmpty && nextPage == .none {
                    DocumentsNotice(
                        icon: filtered ? "magnifyingglass" : "doc.text",
                        text: L.t(filtered ? "documents_empty_search" : "documents_empty")
                    )
                    .listRowStyle()
                }
                ForEach(documents) { document in
                    DocumentRow(document: document) { onOpenDocument(document.id) }.listRowStyle()
                }
                nextPageRow(nextPage)
            }
        }
    }

    private func refreshable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await viewModel.refresh() }
    }

    /// Под последним документом. Следующая пачка грузится, как только конец списка показался; пока список
    /// обновляется, её не просим. Не загрузилась — «Повторить».
    @ViewBuilder
    private func nextPageRow(_ nextPage: NextPage) -> some View {
        switch nextPage {
        case .none:
            EmptyView()
        case .failed:
            HStack {
                Text(L.t("documents_load_more_failed")).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextLinkButton(text: L.t("common_retry"), color: palette.tones.link, action: viewModel.loadMore)
            }
            .padding(.leading, 10)
            .listRowStyle()
        case .available, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .onAppear { if nextPage == .available && !viewModel.isRefreshing { viewModel.loadMore() } }
                .listRowStyle()
        }
    }

    private func filterLabel(_ kind: AgentDocument.Kind?) -> String {
        switch kind {
        case nil: L.t("documents_filter_all")
        case .deck: L.t("documents_filter_decks")
        case .dashboard: L.t("documents_filter_dashboards")
        case .letter: L.t("documents_filter_letters")
        case .other: L.t("documents_kind_other")
        }
    }
}

/// Фильтр-«чип», как FilterChip в Material: выбранный — с галочкой и подложкой.
struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                Text(label).textStyle(Typography.labelLarge)
            }
            .foregroundStyle(selected ? palette.onSecondaryContainer : palette.onSurfaceVariant)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? palette.secondaryContainer : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.clear : palette.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Строка как у чатов в меню: значок вида, название, подпись и когда сделан.
private struct DocumentRow: View {
    let document: AgentDocument
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        DrawerRow(
            title: document.title.isEmpty ? document.kind.label : document.title,
            minHeight: 56,
            action: action,
            leading: { DocumentKindIcon(kind: document.kind) },
            subtitle: document.subtitle.isEmpty ? nil : AnyView(
                Text(document.subtitle).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            ),
            trailing: {
                Text(shortCreatedLabel(document.createdAt)).textStyle(Typography.labelSmall).foregroundStyle(palette.onSurfaceVariant)
            }
        )
    }
}

/// «Шаблоны писем» во вкладке «Документы»: название, вид, тема, кому и когда по шаблону писали. [query] — поиск меню.
/// [onWrite] получает начало просьбы агенту на языке приложения — «Напиши письмо по шаблону «…»: ».
struct LetterTemplatesList: View {
    let viewModel: LetterTemplatesViewModel
    let query: String
    let onWrite: (String) -> Void

    @State private var confirmDelete: LetterTemplate?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch viewModel.list {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let key):
                list { DocumentsNotice(icon: "exclamationmark.circle", text: L.t(key), onRetry: viewModel.retry).listRowStyle() }
            case .loaded(let templates):
                let shown = templates.matching(query)
                list {
                    if shown.isEmpty {
                        let searching = !templates.isEmpty
                        DocumentsNotice(
                            icon: searching ? "magnifyingglass" : "square.and.pencil",
                            text: L.t(searching ? "documents_empty_search" : "letter_templates_empty")
                        )
                        .listRowStyle()
                    }
                    ForEach(shown) { template in
                        TemplateRow(
                            template: template,
                            deleting: viewModel.deleting == template.id,
                            onWrite: { onWrite(L.t("letter_templates_phrase", template.name)) },
                            onDelete: { confirmDelete = template }
                        )
                        .listRowStyle()
                    }
                }
            }
        }
        .snackbar(message: viewModel.messageKey.map { L.t($0) }) { viewModel.messageKey = nil }
        .alert(
            L.t("letter_templates_delete_confirm_title", confirmDelete?.name ?? ""),
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button(L.t("common_cancel"), role: .cancel) {}
            Button(L.t("letter_templates_delete_confirm"), role: .destructive) {
                if let template = confirmDelete { viewModel.delete(template.id) }
            }
        } message: {
            Text(L.t("letter_templates_delete_confirm_text"))
        }
    }

    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await viewModel.refresh() }
    }
}

/// Название, над ним вид, под ним тема и адресат; внизу — когда по нему писали и действия.
private struct TemplateRow: View {
    let template: LetterTemplate
    let deleting: Bool
    let onWrite: () -> Void
    let onDelete: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !template.kindLabel.isEmpty {
                Text(template.kindLabel).textStyle(Typography.labelSmall).foregroundStyle(palette.primary)
            }
            Text(template.name).textStyle(Typography.titleSmall).foregroundStyle(palette.onSurface).lineLimit(2)
            if !template.subject.isEmpty {
                Text(template.subject).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(2)
            }
            if !template.addresseeShort.isEmpty {
                Text(L.t("chat_letter_to", template.addresseeShort)).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            }
            HStack(spacing: 0) {
                let time = shortCreatedLabel(template.usedAt ?? template.createdAt)
                Text(L.t(template.usedAt != nil ? "letter_templates_used" : "letter_templates_created", time))
                    .textStyle(Typography.labelSmall)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onWrite) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                        Text(L.t("letter_templates_write")).textStyle(Typography.labelLarge)
                    }
                    .foregroundStyle(palette.tones.link)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Group {
                        if deleting { ProgressView().controlSize(.small) } else {
                            Image(systemName: "trash").foregroundStyle(palette.onSurfaceVariant)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(deleting)
                .accessibilityLabel(L.t("letter_templates_delete"))
            }
            Rectangle().fill(palette.outlineVariant).frame(height: 1)
        }
        .padding(.leading, 10)
        .padding(.top, Spacing.sm)
    }
}
