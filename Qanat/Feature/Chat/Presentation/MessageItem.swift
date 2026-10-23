import MarkdownUI
import SwiftUI

/// Действия ленты, общие для всех сообщений: голосовые, снимки и файлы документов.
struct MessageActions {
    var playing: VoiceClip?
    var onTogglePlayback: (VoiceClip) -> Void
    var loadPhoto: (_ id: String, _ thumbnail: Bool) async -> Data?
    var onOpenPhoto: (_ id: String) -> Void
    var downloadingDocument: String?
    var onDownloadDocument: (String) -> Void
    var onSaveTemplate: (_ documentId: String, _ name: String) -> Void
}

/// Вопрос — пузырём справа, ответ агента — во всю ширину, как в ChatGPT.
struct MessageItem: View {
    let message: ChatMessage
    let actions: MessageActions

    var body: some View {
        let time = Self.timeFormatter.string(from: message.createdAt)
        if message.role == .assistant {
            AssistantContent(
                caption: stepsCaption(message.steps, inProgress: false),
                trace: message.trace.isEmpty ? nil : AnyView(WorkTraceSummary(trace: message.trace, latencyMs: message.latencyMs)),
                blocks: message.blocks,
                error: message.error,
                actions: actions,
                footer: AnyView(AnswerFooter(message: message, time: time, actions: actions))
            ) {
                if message.hasAudio { VoiceAnswerPlayer(messageId: message.id, actions: actions) }
                if !message.text.isEmpty { AnswerMarkdown(text: message.text) }
            }
        } else if message.hasAudio {
            VoiceBubble(message: message, time: time, actions: actions)
        } else {
            UserBubble(text: message.text, photos: message.photos, time: time, actions: actions)
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// Ответ, который ещё печатается; письмо в нём уже можно скачать — как и в готовом [MessageItem].
struct PendingAnswerItem: View {
    let answer: PendingAnswer
    let actions: MessageActions

    var body: some View {
        let started = !answer.text.isEmpty || !answer.blocks.isEmpty
        let now = stepsCaption(answer.steps, inProgress: true)
        // Шагов ещё нет и сказать нечего — тоже «Работаю…», а не пустая строка.
        let showTrace = !answer.trace.isEmpty || (!started && now == nil && answer.status.isEmpty)
        AssistantContent(
            // Пока ответа нет, подпись у значка стоит вместо него, поэтому крупнее — как в макете.
            caption: started ? now : (now ?? (answer.status.isEmpty ? L.t("chat_thinking") : answer.status)),
            captionIsStatus: !started,
            trace: showTrace ? AnyView(WorkTraceInProgress(trace: answer.trace)) : nil,
            blocks: answer.blocks,
            error: nil,
            actions: actions,
            footer: nil
        ) {
            if !answer.text.isEmpty { AnswerMarkdown(text: answer.text) }
        }
    }
}

/// ▶ / ⏸ для голосового — в истории и в поле ввода.
struct VoicePlayButton: View {
    let isPlaying: Bool
    var enabled = true
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16))
                .foregroundStyle(palette.onSecondaryContainer)
                .frame(width: 40, height: 40)
                .background(palette.secondaryContainer, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .accessibilityLabel(L.t(isPlaying ? "chat_pause" : "chat_play"))
        .frame(width: 48, height: 48)
    }
}

private struct UserBubble: View {
    let text: String
    let photos: [ChatPhoto]
    let time: String
    let actions: MessageActions

    var body: some View {
        BubbleRow {
            VStack(alignment: .trailing, spacing: 4) {
                if !photos.isEmpty { MessagePhotos(photos: photos, actions: actions).padding(.bottom, 4) }
                if !text.isEmpty {
                    Text(text).textStyle(Typography.bodyMedium).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                TimeLabel(time: time)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

struct TimeLabel: View {
    let time: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(time).textStyle(Typography.labelSmall).foregroundStyle(palette.onSurfaceVariant)
    }
}

/// Голосовой вопрос: плеер, под ним расшифровка — когда сервер её прислал (сначала её может не быть).
private struct VoiceBubble: View {
    let message: ChatMessage
    let time: String
    let actions: MessageActions

    @Environment(\.palette) private var palette

    var body: some View {
        let clip = VoiceClip.message(messageId: message.id)
        BubbleRow {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    // Пока сервер не сохранил вопрос, у него нет id — слушать нечего.
                    VoicePlayButton(isPlaying: actions.playing == clip, enabled: message.id != localQuestionId) { actions.onTogglePlayback(clip) }
                    Text(L.t("chat_voice_message")).textStyle(Typography.bodyLarge)
                }
                Group {
                    if !message.photos.isEmpty {
                        MessagePhotos(photos: message.photos, actions: actions).padding(.vertical, 2)
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textStyle(Typography.bodySmall).foregroundStyle(palette.inverseOnSurface.opacity(0.75))
                    }
                    if let error = message.error, !error.isEmpty {
                        Text(error).textStyle(Typography.bodySmall).foregroundStyle(palette.error)
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 4)
                TimeLabel(time: time).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4).padding(.top, 2)
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }
}

/// Плеер голосового ответа агента — над текстом и блоками, как у голосового вопроса.
private struct VoiceAnswerPlayer: View {
    let messageId: String
    let actions: MessageActions

    var body: some View {
        let clip = VoiceClip.message(messageId: messageId)
        HStack(spacing: 8) {
            // Ответ агента приходит уже сохранённым — его запись есть всегда.
            VoicePlayButton(isPlaying: actions.playing == clip) { actions.onTogglePlayback(clip) }
            Text(L.t("chat_voice_message")).textStyle(Typography.bodyLarge)
        }
    }
}

private struct BubbleRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content()
                .foregroundStyle(palette.inverseOnSurface)
                .background(palette.inverseSurface, in: chatBubbleShape)
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }
}

/// Ответ агента: значок с подписью, текст, блоки. [captionIsStatus] — подпись заменяет ещё не начавшийся ответ
/// («Секунду, посмотрю…»), а не поясняет готовый («Проверил поручения · 2 источника»).
private struct AssistantContent<Text_: View>: View {
    let caption: String?
    var captionIsStatus = false
    let trace: AnyView?
    let blocks: [ChatBlock]
    let error: String?
    let actions: MessageActions
    let footer: AnyView?
    @ViewBuilder let text: () -> Text_

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Раскрытый ход работы растёт вниз от значка, а не вокруг его середины.
            HStack(alignment: trace != nil ? .top : .center, spacing: captionIsStatus ? 10 : 8) {
                AgentAvatar()
                // Ход работы — подробнее строки по инструментам и вместо неё.
                if let trace {
                    trace.padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
                } else if let caption {
                    Text(caption)
                        .textStyle(captionIsStatus ? Typography.bodyMedium : Typography.labelMedium.weight(.regular))
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
            text()
            ForEach(blocks.indices, id: \.self) { index in
                BlockView(block: blocks[index], actions: actions)
            }
            if let error {
                Text(error).textStyle(Typography.bodyMedium).foregroundStyle(palette.error)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Под готовым ответом: скопировать, озвучить и время.
private struct AnswerFooter: View {
    let message: ChatMessage
    let time: String
    let actions: MessageActions

    @Environment(\.palette) private var palette

    var body: some View {
        let hasActions = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 0) {
            if hasActions {
                Button { UIPasteboard.general.string = message.text } label: {
                    icon("doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t("chat_copy"))
                // Голосовой ответ звучит своей записью, остальные озвучивает сервер.
                let clip: VoiceClip = message.hasAudio ? .message(messageId: message.id) : .speech(messageId: message.id, text: message.text)
                let isPlaying = actions.playing == clip
                Button { actions.onTogglePlayback(clip) } label: {
                    icon(isPlaying ? "stop.circle" : "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t(isPlaying ? "chat_speak_stop" : "chat_speak"))
            }
            TimeLabel(time: time).padding(.leading, hasActions ? 4 : 0)
        }
        // У кнопок поля под палец, а значки должны стоять ровно по левому краю текста ответа.
        .offset(x: hasActions ? -14 : 0)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(palette.onSurfaceVariant)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// «Проверил поручения · 2 источника» — чем агент искал ответ; пока он работает — «Смотрю поручения…»
/// по последнему вызванному инструменту. nil — агент ничего не искал, только отвечал или оформлял ответ.
func stepsCaption(_ steps: [String], inProgress: Bool) -> String? {
    let sources = answerSources(steps)
    guard let first = sources.first, let last = sources.last else { return nil }
    if inProgress { return L.t(stepLabelKey(last) + "_now") }
    let label = L.t(stepLabelKey(first))
    return sources.count == 1 ? label : L.plural("chat_step_sources", label, sources.count)
}

private func stepLabelKey(_ code: String) -> String {
    switch code {
    case "search_knowledge", "list_assignments", "assignment_stats", "list_meetings", "get_meeting",
         "search_meetings", "list_protocols", "get_protocol", "search_memory":
        "chat_step_\(code)"
    default:
        "chat_step_other"
    }
}

/// Фирменный значок «Q» перед ответом Каната.
struct AgentAvatar: View {
    var size: CGFloat = 26
    var style: QTextStyle = BrandText.avatarTiny
    @Environment(\.palette) private var palette

    var body: some View {
        Text(brandLetter)
            .textStyle(style)
            .foregroundStyle(palette.onPrimary)
            .frame(width: size, height: size)
            .background(palette.primary, in: Circle())
    }
}

/// Ответ агента в markdown — с таблицами и списками (GFM), шрифтами и цветами макета.
struct AnswerMarkdown: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Markdown(text)
            .markdownTheme(.qanat(palette))
            .textSelection(.enabled)
    }
}

extension MarkdownUI.Theme {
    static func qanat(_ palette: Palette) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                FontFamily(.custom("Onest-Regular"))
                FontSize(15)
                ForegroundColor(palette.onSurface)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(palette.primary) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(palette.surfaceVariant)
            }
            .heading1 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(20) }.markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(18) }.markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(16) }.markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label.relativeLineSpacing(.em(0.25)).markdownMargin(top: 0, bottom: 10)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: .em(0.2))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label.markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.85)) }.padding(12)
                }
                .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 10))
                .markdownMargin(top: 0, bottom: 10)
            }
            .table { configuration in
                ScrollView(.horizontal) { configuration.label }
                    .markdownTableBorderStyle(.init(color: palette.outline))
                    .markdownMargin(top: 0, bottom: 10)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle { if configuration.row == 0 { FontWeight(.semibold) }; FontSize(13) }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
    }
}
