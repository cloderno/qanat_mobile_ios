import SwiftUI

/// Вкладки меню: чаты и документы, которые агент в них сделал.
enum DrawerTab: Int { case chats, documents }

/// Меню чатов — одно и для шторки, и для постоянной колонки слева на широком экране.
/// [documentsList] — вкладка «Документы»; по ним ищет то же поле поиска — [documentsQuery].
struct ChatDrawer<Documents: View>: View {
    let compact: Bool
    @Binding var tab: DrawerTab
    let pinnedChats: [Chat]
    let recentChats: [Chat]
    let selectedId: String?
    let profileName: String?
    let profileInitials: String
    let profileAvatarURL: String?
    let glasses: GlassesStatus
    let glassesName: String?
    @Binding var chatQuery: String
    @Binding var documentsQuery: String
    let onRefresh: () async -> Void
    let onNewChat: () -> Void
    let onOpenChat: (String) -> Void
    let onLoadMore: () -> Void
    let onTogglePin: (String) -> Void
    let onRenameChat: (String, String) -> Void
    let onDeleteChat: (String) -> Void
    let onOpenSettings: () -> Void
    let onOpenGlasses: () -> Void
    let onOpenGallery: () -> Void
    @ViewBuilder let documentsList: () -> Documents

    @Environment(\.palette) private var palette

    var body: some View {
        let pinned = pinnedChats.matching(chatQuery)
        VStack(spacing: 0) {
            if compact { compactHeader } else { header }
            switch tab {
            case .chats:
                ChatList(
                    pinned: pinned,
                    recent: recentChats.matching(chatQuery),
                    selectedId: selectedId,
                    compact: compact,
                    onRefresh: onRefresh,
                    onOpenChat: onOpenChat,
                    onLoadMore: onLoadMore,
                    onTogglePin: onTogglePin,
                    onRenameChat: onRenameChat,
                    onDeleteChat: onDeleteChat
                )
            case .documents:
                documentsList()
            }
            // Подвал с профилем; на телефоне боком его заменяет меню аватара в шапке.
            if !compact {
                Rectangle().fill(palette.outlineVariant).frame(height: 1).padding(.horizontal, Spacing.md)
                DrawerRow(
                    title: profileName ?? L.t("settings_title"),
                    titleWeight: .medium,
                    action: onOpenSettings,
                    leading: {
                        Avatar(initials: profileInitials, imageURL: profileAvatarURL, size: 36, textStyle: Typography.bodySmall.weight(.semibold))
                    },
                    trailing: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 17)).foregroundStyle(palette.onSurfaceVariant)
                    }
                )
                .padding(Spacing.md)
            }
        }
        .background(palette.surfaceContainer)
    }

    private var searchField: some View {
        DrawerSearchField(
            query: tab == .chats ? $chatQuery : $documentsQuery,
            hint: L.t(tab == .chats ? "chat_search_hint" : "documents_search_hint")
        )
    }

    private var tabPicker: some View {
        SegmentedPicker(
            options: [L.t("chat_list_title"), L.t("documents_tab")],
            selectedIndex: tab.rawValue,
            // Телефон боком: вкладки вместе с подложкой — 36pt, каждый pt в высоту идёт под чаты.
            segmentHeight: compact ? 28 : 36,
            trackRadius: 12,
            segmentRadius: 9,
            textStyle: Typography.labelLarge,
            onSelect: { tab = DrawerTab(rawValue: $0) ?? .chats }
        )
    }

    private var header: some View {
        VStack(spacing: 0) {
            searchField
            Spacer().frame(height: 14)
            NewChatButton(action: onNewChat)
            Spacer().frame(height: Spacing.sm)
            VStack(spacing: 2) {
                // Очки не добавлены — одна спокойная строка «Подключить очки», без статуса и цвета.
                DrawerRow(
                    title: L.t(glasses == .notConnected ? "voice_glasses_connect" : "glasses_title"),
                    highlighted: glasses == .ready,
                    titleWeight: .medium,
                    minHeight: 56,
                    action: onOpenGlasses,
                    leading: {
                        GlassesIcon(tint: palette.onSurface)
                            .frame(width: 20, height: 20)
                            .frame(width: 32, height: 32)
                            .background(palette.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
                    },
                    subtitle: glasses == .notConnected ? nil : AnyView(GlassesStatusLine(status: glasses, deviceName: glassesName))
                )
                DrawerRow(
                    title: L.t("gallery_title"),
                    titleWeight: .medium,
                    action: onOpenGallery,
                    leading: {
                        Image(systemName: "photo").font(.system(size: 17)).foregroundStyle(palette.onSurface).frame(width: 32, height: 32)
                    }
                )
            }
            Spacer().frame(height: 14)
            Rectangle().fill(palette.outlineVariant).frame(height: 1).padding(.horizontal, 6)
            Spacer().frame(height: Spacing.md)
            tabPicker
        }
        .padding(Spacing.md)
    }

    /// Телефон боком: «Новый чат» — кнопкой у поиска, а настройки, галерея и очки — в меню аватара рядом.
    private var compactHeader: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                searchField
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: 44, height: 44)
                        .background(palette.primary, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel(L.t("chat_new"))
                Menu {
                    Button(action: onOpenSettings) { Label(L.t("settings_title"), systemImage: "slider.horizontal.3") }
                    Button(action: onOpenGallery) { Label(L.t("gallery_title"), systemImage: "photo") }
                    Button(action: onOpenGlasses) {
                        Label(L.t(glasses == .notConnected ? "voice_glasses_connect" : "glasses_title"), systemImage: "eyeglasses")
                    }
                } label: {
                    Avatar(initials: profileInitials, imageURL: profileAvatarURL, size: 32, textStyle: Typography.labelMedium)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(profileName ?? L.t("chat_menu"))
            }
            tabPicker
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
    }
}

/// «Новый чат» — главная кнопка шторки, как «Чат» в ChatGPT: сразу под поиском, заметнее остальных строк.
private struct NewChatButton: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "square.and.pencil").font(.system(size: 17, weight: .medium))
                Text(L.t("chat_new")).textStyle(Typography.bodyMedium.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.onPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: 48)
            .background(palette.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension Array where Element == Chat {
    /// Чаты, в названии которых есть [query]; пустой запрос — все.
    func matching(_ query: String) -> [Chat] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? self : filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// Вкладка «Чаты»: сверху «Закреплённые», под ними «Недавние» по датам, последние сверху.
/// Долгое нажатие на чат — меню: закрепить, переименовать, удалить.
private struct ChatList: View {
    let pinned: [Chat]
    let recent: [Chat]
    let selectedId: String?
    let compact: Bool
    let onRefresh: () async -> Void
    let onOpenChat: (String) -> Void
    let onLoadMore: () -> Void
    let onTogglePin: (String) -> Void
    let onRenameChat: (String, String) -> Void
    let onDeleteChat: (String) -> Void

    @State private var renaming: Chat?
    @State private var deleting: Chat?
    @Environment(\.palette) private var palette

    var body: some View {
        // Сегодняшняя дата меняется в полночь — подписи «Сегодня» и «12:25» обновляются вместе с ней.
        TimelineView(.everyMinute) { context in
            let grouped = recent.groupedByDate(now: context.date) { $0.updatedAt }
            List {
                if !pinned.isEmpty {
                    sectionTitle(L.t("chat_section_pinned"))
                    ForEach(pinned) { row($0, now: context.date) }
                    if !grouped.isEmpty { sectionTitle(L.t("chat_section_recent")) }
                }
                ForEach(grouped, id: \.0) { group, chats in
                    Text(group.label)
                        .textStyle(compact ? Typography.labelSmall : Typography.labelMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .padding(.horizontal, 10)
                        .padding(.top, compact ? Spacing.xs : Spacing.sm)
                        .padding(.bottom, compact ? 2 : Spacing.sm)
                        .listRowStyle()
                    ForEach(chats) { chat in
                        row(chat, now: context.date)
                            // Следующая пачка чатов — когда до конца списка осталось несколько строк.
                            .onAppear { if chat.id == recent.suffix(5).first?.id { onLoadMore() } }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await onRefresh() }
        }
        .modifier(RenameChatAlert(chat: $renaming) { chat, title in onRenameChat(chat.id, title) })
        .modifier(DeleteChatAlert(chat: $deleting) { chat in onDeleteChat(chat.id) })
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .textStyle(Typography.labelLarge.weight(.semibold))
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, 10)
            .padding(.top, compact ? Spacing.sm : Spacing.md)
            .padding(.bottom, compact ? 2 : Spacing.xs)
            .listRowStyle()
    }

    private func row(_ chat: Chat, now: Date) -> some View {
        let untitled = L.t("chat_untitled")
        return DrawerRow(
            title: chat.title.isEmpty ? untitled : chat.title,
            selected: chat.id == selectedId,
            minHeight: compact ? 40 : 44,
            leadingGap: Spacing.sm,
            verticalPadding: compact ? 3 : Spacing.xs,
            action: { onOpenChat(chat.id) },
            leading: { sourceIcon(chat) },
            subtitle: subtitle(chat, now: now),
            titleTrailing: compact
                ? AnyView(Text(shortActivityLabel(chat.updatedAt, now: now)).textStyle(Typography.labelSmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1))
                : nil
        )
        .contextMenu {
            Button { onTogglePin(chat.id) } label: {
                Label(L.t(chat.pinned ? "chat_menu_unpin" : "chat_menu_pin"), systemImage: chat.pinned ? "pin.slash" : "pin")
            }
            Button { renaming = chat } label: { Label(L.t("chat_menu_rename"), systemImage: "pencil") }
            Button(role: .destructive) { deleting = chat } label: { Label(L.t("chat_menu_delete"), systemImage: "trash") }
        }
        .listRowStyle()
    }

    /// Под названием чата: начало последнего сообщения и когда оно было — «Сегодня, 12:25». Боком — только начало.
    private func subtitle(_ chat: Chat, now: Date) -> AnyView? {
        // Переносы строк в начале сообщения — пробелы: в одну строку под названием.
        let preview = chat.preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let previewText = Text(preview).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        if compact { return preview.isEmpty ? nil : AnyView(previewText) }
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            if !preview.isEmpty { previewText }
            Text(lastActivityLabel(chat.updatedAt, now: now)).textStyle(Typography.labelSmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        })
    }

    @ViewBuilder
    private func sourceIcon(_ chat: Chat) -> some View {
        switch chat.source {
        case .voice: Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(palette.onSurfaceVariant)
        case .glasses: GlassesIcon(tint: palette.onSurfaceVariant).frame(width: 16, height: 16)
        case .text: EmptyView()
        }
    }
}

extension View {
    /// Строка списка меню без системных отступов, разделителей и фона.
    func listRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct DrawerSearchField: View {
    @Binding var query: String
    let hint: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(palette.onSurfaceVariant)
            TextField("", text: $query, prompt: Text(hint).foregroundStyle(palette.onSurfaceVariant))
                .font(Typography.bodyMedium.font)
                .foregroundStyle(palette.onSurface)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 44)
        .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Строка меню. [selected] — открытый чат (тил), [highlighted] — нейтральная подсветка пункта «Смарт-очки»,
/// пока очки подключены: тил в меню означает только выбранный чат. Ею же нарисованы документы.
struct DrawerRow<Leading: View, Trailing: View>: View {
    let title: String
    var selected = false
    var highlighted = false
    var titleWeight: Font.Weight = .regular
    var minHeight: CGFloat = 48
    var leadingGap: CGFloat = Spacing.md
    var verticalPadding: CGFloat = Spacing.xs
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    var subtitle: AnyView?
    var titleTrailing: AnyView?
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.palette) private var palette

    init(
        title: String,
        selected: Bool = false,
        highlighted: Bool = false,
        titleWeight: Font.Weight = .regular,
        minHeight: CGFloat = 48,
        leadingGap: CGFloat = Spacing.md,
        verticalPadding: CGFloat = Spacing.xs,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        subtitle: AnyView? = nil,
        titleTrailing: AnyView? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.selected = selected
        self.highlighted = highlighted
        self.titleWeight = titleWeight
        self.minHeight = minHeight
        self.leadingGap = leadingGap
        self.verticalPadding = verticalPadding
        self.action = action
        self.leading = leading
        self.subtitle = subtitle
        self.titleTrailing = titleTrailing
        self.trailing = trailing
    }

    var body: some View {
        let background = selected ? palette.primaryContainer : (highlighted ? palette.surfaceVariant : Color.clear)
        Button(action: action) {
            HStack(spacing: leadingGap) {
                leading()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.sm) {
                        Text(title)
                            .textStyle(Typography.bodyMedium.weight(titleWeight))
                            .foregroundStyle(palette.onSurface)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        titleTrailing
                    }
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
    }
}

/// Шторка поверх экрана: выезжает слева, закрывается тапом по вуали или свайпом влево.
struct SideDrawer<Drawer: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let drawer: () -> Drawer
    @ViewBuilder let content: () -> Content

    @GestureState private var drag: CGFloat = 0
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let width = min(318, proxy.size.width * 0.85)
            let offset = isOpen ? min(0, drag) : -width
            ZStack(alignment: .leading) {
                content()
                // Стандартная вуаль на тёмном чате почти незаметна — меню сливалось бы с экраном под ним.
                Color.black
                    .opacity(isOpen ? (palette.isDark ? 0.65 : 0.32) * Double(1 + offset / width) : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(isOpen)
                    .onTapGesture { isOpen = false }
                drawer()
                    .frame(width: width)
                    .offset(x: offset)
                    .gesture(
                        DragGesture()
                            .updating($drag) { value, state, _ in state = value.translation.width }
                            .onEnded { value in if value.translation.width < -width / 3 { isOpen = false } }
                    )
            }
            .animation(.easeOut(duration: 0.25), value: isOpen)
        }
    }
}
