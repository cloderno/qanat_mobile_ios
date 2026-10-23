import AVFoundation
import PhotosUI
import QuickLook
import SwiftUI

struct ChatScreen: View {
    @State var viewModel: ChatViewModel
    let documentsViewModel: DocumentsViewModel
    let templatesViewModel: LetterTemplatesViewModel
    /// В голосовой режим из чата [chatId] (nil — новый чат): разговор пойдёт в него.
    let onOpenVoice: (_ chatId: String?) -> Void
    let onOpenSettings: () -> Void
    let onOpenGlasses: () -> Void
    let onOpenGallery: () -> Void
    let onOpenGlassesGuide: () -> Void
    let onOpenDocument: (String) -> Void
    /// Чат, который надо открыть: из push, из документа или из голосового разговора. Экран обнуляет его, открыв.
    @Binding var initialChatId: String?
    /// Вернулись с экрана документа — меню сразу открыто на «Документах», откуда его открыли.
    @Binding var showDocuments: Bool
    /// id чатов, в которые только что записал голосовой разговор, — открытый перечитывается сразу.
    var chatChanges: (() -> AsyncStream<String>)?
    /// Ход работы Каната в голосовом разговоре: в его чате — как ответ, который ещё пишется.
    var voiceTrace: LiveTrace?
    /// Над полем ввода: панель идущего голосового разговора; nil — разговора нет.
    var voicePanel: AnyView?

    @State private var drawerOpen = false
    @State private var drawerTab: DrawerTab = .chats
    @State private var chatQuery = ""
    @State private var documentsQuery = ""
    @State private var pickerShown = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var documentPreview: URL?
    @Environment(\.windowLayout) private var layout
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let state = viewModel.state
        // Очки без регистрации SDK не отдаёт вовсе, поэтому «подключены к Qanat» — это есть ли они в состоянии.
        let glasses = glassesStatus(registered: state.glassesInfo != nil, info: state.glassesInfo)
        Group {
            if layout.twoPane {
                // Ширина ≥ 600pt (телефон боком, планшет) — список чатов постоянной колонкой слева, как на сайте.
                HStack(spacing: 0) {
                    drawer(glasses: glasses).frame(width: 300)
                    Rectangle().fill(palette.outlineVariant).frame(width: 1)
                    conversation(glasses: glasses)
                }
            } else {
                SideDrawer(isOpen: $drawerOpen) {
                    drawer(glasses: glasses)
                } content: {
                    conversation(glasses: glasses)
                }
            }
        }
        .background(palette.background)
        .onAppear {
            if showDocuments {
                drawerTab = .documents
                drawerOpen = true
                showDocuments = false
            }
            openInitialChat()
        }
        .onChange(of: initialChatId) { _, _ in openInitialChat() }
        // Пока экран виден — сверка с сервером, как на сайте; при возвращении на него — сразу.
        .task { await viewModel.keepInSync(chatChanges: chatChanges?()) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { viewModel.onScreenResumed() } }
        .onChange(of: documentsQuery) { _, query in documentsViewModel.onQueryChange(query) }
        // Скачанный файл открываем один раз — дальше он лежит в «Файлах».
        .onChange(of: state.documentToOpen) { _, document in
            guard let document else { return }
            documentPreview = document.url
            viewModel.onDocumentOpened()
        }
        .quickLookPreview($documentPreview)
        .photosPicker(isPresented: $pickerShown, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    viewModel.onPhotoPicked(image)
                }
            }
        }
    }

    private func openInitialChat() {
        guard let id = initialChatId else { return }
        viewModel.onOpenChat(id)
        initialChatId = nil
    }

    private func closeDrawerAfter(_ action: () -> Void) {
        action()
        if !layout.twoPane { drawerOpen = false }
    }

    private func drawer(glasses: GlassesStatus) -> some View {
        let state = viewModel.state
        return ChatDrawer(
            compact: layout.compactHeight,
            tab: $drawerTab,
            pinnedChats: state.pinnedChats,
            recentChats: state.recentChats,
            selectedId: state.chat?.id,
            profileName: state.profileName,
            profileInitials: state.profileInitials,
            profileAvatarURL: state.profileAvatarURL,
            glasses: glasses,
            glassesName: state.glassesInfo?.name,
            chatQuery: $chatQuery,
            documentsQuery: $documentsQuery,
            onRefresh: { await viewModel.onRefreshChats() },
            onNewChat: { closeDrawerAfter(viewModel.onNewChat) },
            onOpenChat: { id in closeDrawerAfter { viewModel.onOpenChat(id) } },
            onLoadMore: viewModel.loadMoreChats,
            onTogglePin: viewModel.onTogglePin,
            onRenameChat: { id, title in viewModel.onRenameChat(id, title: title) },
            onDeleteChat: viewModel.onDeleteChat,
            onOpenSettings: { closeDrawerAfter(onOpenSettings) },
            onOpenGlasses: { closeDrawerAfter(onOpenGlasses) },
            onOpenGallery: { closeDrawerAfter(onOpenGallery) }
        ) {
            DocumentsList(
                viewModel: documentsViewModel,
                onOpenDocument: onOpenDocument,
                templates: {
                    LetterTemplatesList(
                        viewModel: templatesViewModel,
                        query: documentsQuery,
                        onWrite: { phrase in closeDrawerAfter { viewModel.onWriteFromTemplate(phrase) } }
                    )
                },
                onShowTemplates: templatesViewModel.onShown
            )
        }
    }

    private func conversation(glasses: GlassesStatus) -> some View {
        let state = viewModel.state
        // Свой ответ, потом ход работы голосового разговора, потом — вопроса с другого устройства.
        let answer = state.answer ?? [voiceTrace, state.remoteWork].compactMap { $0 }.first { $0.chatId == state.chat?.id }
            .map { PendingAnswer(trace: $0.steps) }
        return VStack(spacing: 0) {
            ChatTopBar(
                title: state.chat?.title,
                glasses: glasses,
                // Меню и так на экране — кнопка открыть его не нужна.
                onMenu: layout.twoPane ? nil : { drawerOpen = true },
                onOpenGlasses: onOpenGlasses
            )
            ChatMessages(
                state: state,
                answer: answer,
                actions: MessageActions(
                    playing: state.playing,
                    onTogglePlayback: viewModel.onTogglePlayback,
                    loadPhoto: { id, thumbnail in await viewModel.loadPhoto(id, thumbnail: thumbnail) },
                    onOpenPhoto: { _ in },
                    downloadingDocument: state.downloadingDocument,
                    onDownloadDocument: viewModel.onDownloadDocument,
                    onSaveTemplate: { id, name in viewModel.onSaveLetterTemplate(documentId: id, name: name) }
                ),
                onRefresh: { await viewModel.onRefreshChat() },
                onLoadEarlier: viewModel.onLoadEarlier
            ) {
                NewChatGreeting(
                    name: state.greetingName,
                    // Подсказка про кнопку на очках — только когда очки надеты: иначе нажимать нечего.
                    showGlassesHint: glasses == .ready,
                    onSuggestion: viewModel.onSuggestion,
                    onOpenGlassesGuide: onOpenGlassesGuide
                )
            }
            ChatInput(
                viewModel: viewModel,
                compact: layout.compactHeight,
                onAttach: { pickerShown = true },
                onOpenVoice: { onOpenVoice(state.chat?.id) },
                voicePanel: voicePanel
            )
        }
        .background(palette.background)
    }
}

/// Слева меню, по центру — название открытого чата (на главном экране пусто). Справа — значок очков в цвете
/// их состояния, только если очки добавлены. [onMenu] nil — меню стоит колонкой рядом: кнопки нет.
private struct ChatTopBar: View {
    let title: String?
    let glasses: GlassesStatus
    let onMenu: (() -> Void)?
    let onOpenGlasses: () -> Void

    @Environment(\.windowLayout) private var layout
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            if let onMenu {
                IconButton(systemName: "line.3.horizontal", accessibilityLabel: L.t("chat_menu"), action: onMenu)
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
            Text(title ?? "")
                .textStyle(Typography.titleSmall)
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
            if glasses != .notConnected {
                // Значок очков без подписи — что с очками, говорит цвет и описание для VoiceOver.
                let (tint, description): (Color, String) = switch glasses {
                case .ready: (palette.tones.connected, L.t("chat_glasses"))
                case .connected: (palette.onSurface, L.t("chat_glasses"))
                case .takenOff: (palette.tones.warning, L.t("glasses_status_taken_off"))
                case .offline: (palette.outline, L.t("glasses_status_offline"))
                case .notConnected: (palette.onSurface, L.t("voice_glasses_connect"))
                }
                Button(action: onOpenGlasses) {
                    GlassesIcon(tint: tint).frame(width: 24, height: 24).frame(width: 48, height: 48)
                }
                .accessibilityLabel(description)
            } else {
                // Пустое место под размер кнопки меню — название остаётся по центру.
                Color.clear.frame(width: 48, height: 48)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: layout.topBarHeight)
    }
}

private struct ChatMessages<Empty: View>: View {
    let state: ChatUiState
    let answer: PendingAnswer?
    let actions: MessageActions
    let onRefresh: () async -> Void
    let onLoadEarlier: () -> Void
    @ViewBuilder let emptyContent: () -> Empty

    // Открытый снимок помним здесь, а не в его сообщении: пришедший ответ прокручивает ленту.
    @State private var openedPhoto: String?
    @State private var opened = false
    @State private var previousLastId: String?
    @State private var visible = Set<String>()

    var body: some View {
        if state.isOpening {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.messages.isEmpty && answer == nil {
            // Прокрутка — на случай маленького экрана, крупного шрифта или открытой клавиатуры.
            ScrollView { emptyContent().frame(maxWidth: .infinity) }
                .defaultScrollAnchor(.center)
                .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if state.hasEarlier {
                            // Показался верх истории — подгружаем более ранние сообщения.
                            ProgressView().frame(maxWidth: .infinity).onAppear(perform: onLoadEarlier)
                        }
                        ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, message in
                            let day = Calendar.current.startOfDay(for: message.createdAt)
                            if index == 0 || Calendar.current.startOfDay(for: state.messages[index - 1].createdAt) != day {
                                DateSeparator(date: day)
                            }
                            MessageItem(message: message, actions: withOpenPhoto(actions))
                                .id(message.id)
                                .onAppear { visible.insert(message.id) }
                                .onDisappear { visible.remove(message.id) }
                        }
                        if let answer {
                            PendingAnswerItem(answer: answer, actions: withOpenPhoto(actions))
                                .id("answer")
                                .onAppear { visible.insert("answer") }
                                .onDisappear { visible.remove("answer") }
                        }
                    }
                    .padding(16)
                    .readableWidth()
                }
                .refreshable { await onRefresh() }
                .scrollDismissesKeyboard(.interactively)
                // Пока ответ печатается, список не двигаем. Прокручиваем, только когда внизу появилось новое
                // сообщение — к его началу, чтобы длинный ответ читался сверху. Открытый чат показываем сразу.
                // Ответ, пришедший сверкой, не утаскивает того, кто листает историю выше.
                .onChange(of: state.messages.last?.id, initial: true) { _, lastId in
                    guard let lastId else { return }
                    let atBottom = previousLastId == nil || visible.contains(previousLastId!) || visible.contains("answer")
                    let ownQuestion = state.messages.last?.role == .user
                    if !opened {
                        proxy.scrollTo(lastId, anchor: .top)
                    } else if atBottom || ownQuestion {
                        withAnimation { proxy.scrollTo(lastId, anchor: .top) }
                    }
                    previousLastId = lastId
                    opened = true
                }
            }
            .fullScreenCover(item: Binding(get: { openedPhoto.map(IdentifiedString.init) }, set: { openedPhoto = $0?.value })) { photo in
                PhotoViewer(id: photo.value, load: actions.loadPhoto) { openedPhoto = nil }
            }
        }
    }

    private func withOpenPhoto(_ actions: MessageActions) -> MessageActions {
        var copy = actions
        copy.onOpenPhoto = { openedPhoto = $0 }
        return copy
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

/// «Сегодня / Вчера / 7 октября» — разделитель между сообщениями за разные дни, как в WhatsApp.
private struct DateSeparator: View {
    let date: Date
    @Environment(\.palette) private var palette

    var body: some View {
        Text(label)
            .textStyle(Typography.labelMedium)
            .foregroundStyle(palette.onSurfaceVariant)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(palette.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L.t("chat_date_today") }
        if calendar.isDateInYesterday(date) { return L.t("chat_date_yesterday") }
        let formatter = DateFormatter()
        formatter.locale = LanguageSettings.shared.language.locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "dMMMM" : "dMMMMyyyy")
        return formatter.string(from: date)
    }
}

/// Новый чат: приветствие по имени и отчеству, готовые вопросы и, если есть очки, подсказка про их кнопку.
private struct NewChatGreeting: View {
    let name: String?
    let showGlassesHint: Bool
    let onSuggestion: (String) -> Void
    let onOpenGlassesGuide: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(brandLetter)
                    .textStyle(BrandText.avatarLarge)
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 52, height: 52)
                    .background(palette.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(name.map { L.t("chat_greeting", $0) } ?? L.t("chat_empty"))
                    .textStyle(BrandText.greeting)
                    .foregroundStyle(palette.onSurface)
            }
            VStack(spacing: Spacing.sm) {
                ForEach(["chat_suggestion_assignments", "chat_suggestion_meeting", "chat_suggestion_metrics"], id: \.self) { key in
                    let suggestion = L.t(key)
                    Button { onSuggestion(suggestion) } label: {
                        Text(suggestion)
                            .textStyle(Typography.bodyMedium)
                            .foregroundStyle(palette.onSurface)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.suggestion, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.suggestion, style: .continuous).stroke(palette.outline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            if showGlassesHint {
                // Ведёт на инструкцию по кнопке камеры на очках.
                Button(action: onOpenGlassesGuide) {
                    HStack(spacing: 10) {
                        GlassesIcon(tint: palette.onPrimaryContainer).frame(width: 18, height: 18)
                        Text(L.t("voice_glasses_hint")).textStyle(Typography.bodySmall).foregroundStyle(palette.onPrimaryContainer)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.primaryContainer, in: RoundedRectangle(cornerRadius: Radius.suggestion, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, Spacing.lg)
        .readableWidth()
    }
}

/// Поле ввода как в ChatGPT: слева «Прикрепить снимок», справа микрофон голосового сообщения и кнопка
/// голосового режима, которую сменяет «Отправить», как только есть что отправить. Записанное голосовое встаёт
/// в поле вместо текста — его можно прослушать, удалить или отправить. Прикреплённый снимок — над полем.
private struct ChatInput: View {
    let viewModel: ChatViewModel
    let compact: Bool
    let onAttach: () -> Void
    let onOpenVoice: () -> Void
    let voicePanel: AnyView?

    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let state = viewModel.state
        VStack(alignment: .leading, spacing: Spacing.sm) {
            voicePanel
            if let key = state.errorKey ?? state.noticeKey {
                Text(L.t(key))
                    .textStyle(Typography.bodySmall)
                    .foregroundStyle(state.errorKey != nil ? palette.error : palette.onSurfaceVariant)
                    .padding(.leading, 16)
            }
            if let photo = state.attachedPhoto { attachedPhoto(photo) }
            switch state.voiceInput {
            case .recording:
                RecordingBar(compact: compact, onDone: viewModel.onRecordDone, onCancel: viewModel.onRecordCancel)
            case .ready(let recording):
                pill {
                    let clip = VoiceClip.draft(recording.file)
                    HStack(spacing: 8) {
                        VoicePlayButton(isPlaying: state.playing == clip) { viewModel.onTogglePlayback(clip) }
                        Text(L.t("chat_voice_draft", formatDuration(ms: recording.durationMs)))
                            .textStyle(Typography.bodyLarge)
                            .foregroundStyle(palette.onSurface)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(systemName: "trash", accessibilityLabel: L.t("chat_delete_voice"), action: viewModel.onDeleteRecording)
                    sendButton(enabled: state.canSend)
                }
            case .none:
                pill {
                    IconButton(systemName: "plus", size: 21, accessibilityLabel: L.t("chat_attach"), action: onAttach)
                    // Телефон боком — одна строка; стоя поле растёт до шести строк.
                    TextField(
                        "",
                        text: Binding(get: { viewModel.state.input }, set: { viewModel.onInputChange($0) }),
                        prompt: Text(L.t("chat_input_hint")).foregroundStyle(palette.onSurfaceVariant),
                        axis: .vertical
                    )
                    .font(Typography.bodyLarge.font)
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(compact ? 1...1 : 1...6)
                    .focused($focused)
                    .padding(.vertical, compact ? 6 : 10)
                    .frame(maxWidth: .infinity)
                    IconButton(systemName: "mic", size: 20, accessibilityLabel: L.t("chat_dictate"), action: startRecording)
                    // Есть что отправить — голосовой режим недоступен, на его месте «Отправить».
                    if !state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.attachedPhoto != nil {
                        sendButton(enabled: state.canSend)
                    } else {
                        Button(action: onOpenVoice) {
                            VoiceModeIcon(tint: palette.onPrimary)
                                .frame(width: 22, height: 22)
                                .frame(width: 40, height: 40)
                                .background(palette.primary, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 48, height: 48)
                        .accessibilityLabel(L.t("chat_voice_mode"))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 8)
        .onChange(of: state.focusInput) { _, focus in
            guard focus else { return }
            focused = true
            viewModel.onInputFocused()
        }
    }

    /// Разрешение на микрофон спрашиваем до записи; без него запись не начнётся и покажет «нет микрофона».
    private func startRecording() {
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            viewModel.onRecordStart()
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.xs, content: content)
            .padding(compact ? 2 : 6)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(palette.outline, lineWidth: 1))
    }

    private func sendButton(enabled: Bool) -> some View {
        Button(action: viewModel.onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? palette.onPrimary : palette.onSurface.opacity(0.38))
                .frame(width: 40, height: 40)
                .background(enabled ? palette.primary : palette.onSurface.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(width: 48, height: 48)
        .accessibilityLabel(L.t("chat_send"))
    }

    /// Снимок, который уйдёт со следующим вопросом.
    private func attachedPhoto(_ image: UIImage) -> some View {
        HStack(spacing: Spacing.md) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            Text(L.t("chat_attached_photo")).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(systemName: "xmark", accessibilityLabel: L.t("chat_remove_photo"), action: viewModel.onRemovePhoto)
        }
        .padding(.leading, 6)
    }
}

/// Идёт запись голосового: таймер, «Отмена» и крупная «Готово».
private struct RecordingBar: View {
    let compact: Bool
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var startedAt = Date()
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: 10) {
                Circle().fill(palette.error).frame(width: 10, height: 10)
                // 0:00, 0:01… — сколько идёт запись, с её появления на экране.
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(startedAt))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(Typography.bodyMedium.weight(.semibold).font.monospacedDigit())
                        .foregroundStyle(palette.onSurface)
                }
                Text(L.t("chat_dictation_listening"))
                    .textStyle(Typography.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onCancel) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(L.t("common_cancel")).textStyle(Typography.bodySmall)
                    }
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .frame(height: compact ? 52 : 56)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(palette.outline, lineWidth: 1))
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: compact ? 52 : 64, height: compact ? 52 : 64)
                    .background(palette.primary, in: Circle())
                    .background(Circle().fill(palette.primary.opacity(0.14)).padding(-8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("chat_dictation_done"))
        }
    }
}
