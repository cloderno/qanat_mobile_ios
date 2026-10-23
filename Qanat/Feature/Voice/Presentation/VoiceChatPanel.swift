import Combine
import SwiftUI
import UserNotifications

/// Что показать в панели голосового режима над полем ввода чата.
enum VoicePanelStatus: Equatable {
    /// Разговор идёт: что сейчас делает голосовой режим.
    case live(labelKey: String)
    /// Команда оборвалась ошибкой — иначе пользователь в чате и не узнал бы, что разговора больше нет.
    case failed(labelKey: String)

    var labelKey: String {
        switch self {
        case .live(let key), .failed(let key): key
        }
    }
}

/// Состояние панели по состоянию голосового режима; nil — панель не нужна (покой, голосовое пишется или уходит).
/// Выключенный микрофон важнее «слушаю» — Канат не слышит, — но не того, что он сейчас думает или говорит.
func voicePanelStatus(_ state: VoiceUiState, muted: Bool) -> VoicePanelStatus? {
    switch state {
    case .connecting: return .live(labelKey: "voice_panel_connecting")
    case .talking(_, _, let kanat):
        switch kanat {
        case .speaking: return .live(labelKey: "voice_panel_speaking")
        case .thinking: return .live(labelKey: "voice_panel_thinking")
        case .listening: return .live(labelKey: muted ? "voice_panel_muted" : "voice_panel_listening")
        }
    case .error(let key, _): return .failed(labelKey: key)
    case .idle, .recordingNote, .sendingNote, .answeringNote: return nil
    }
}

/// Разговор идёт, а пользователь в чате: что делает голосовой режим, возврат на его экран и «Завершить».
/// После ошибки — её текст, экран голоса и «Закрыть» ([onEnd] тогда убирает ошибку).
/// [compact] — низкое окно (телефон боком): панель теснее.
struct VoiceChatPanel: View {
    let status: VoicePanelStatus
    let compact: Bool
    let onOpenVoice: () -> Void
    let onEnd: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        let failed = if case .failed = status { true } else { false }
        let foreground = failed ? palette.onErrorContainer : palette.onPrimaryContainer
        HStack(spacing: 8) {
            Button(action: onOpenVoice) {
                HStack(spacing: 8) {
                    VoiceModeIcon(tint: foreground).frame(width: 20, height: 20)
                    // Крупный шрифт: строка переносится на две, а не выталкивает кнопки за край.
                    Text(L.t("voice_panel_status", L.t(status.labelKey)))
                        .textStyle(Typography.bodyMedium)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
                }
                .foregroundStyle(foreground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("voice_panel_open"))
            TextLinkButton(text: L.t(failed ? "voice_panel_dismiss" : "voice_stop"), color: palette.error, action: onEnd)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, compact ? 0 : 2)
        .frame(minHeight: compact ? 40 : 48)
        .background(failed ? palette.errorContainer : palette.primaryContainer, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Когда звучит сигнал связи с очками: только на новую связь — первую или после разрыва не короче 15 с — и не чаще
/// раза в 30 с. Короткий разрыв Qanat сам восстанавливает за секунды — звенеть после каждого незачем.
struct LinkSignalGate {
    static let minGapMs: Int64 = 15_000
    static let minIntervalMs: Int64 = 30_000

    /// Номер последней связи, о которой уже решили, — сыграли или промолчали.
    private var lastNumber = 0
    private var lastSignalAtMs: Int64?

    /// [start] — последнее начало связи, [nowMs] — монотонное время. true — пора сыграть сигнал.
    mutating func shouldSignal(_ start: GlassesLinkStart?, microphoneOpen: Bool, nowMs: Int64) -> Bool {
        guard let start, start.number > lastNumber else { return false }
        lastNumber = start.number
        if let gap = start.gapMs, gap < Self.minGapMs { return false }
        // Сигнал в открытый микрофон ушёл бы в заметку или разговор — такую связь пропускаем молча.
        if microphoneOpen { return false }
        if let last = lastSignalAtMs, nowMs - last < Self.minIntervalMs { return false }
        lastSignalAtMs = nowMs
        return true
    }
}

/// Сигнал «очки на связи с Qanat» — без него не понять, подключились очки к Qanat или только к Meta AI.
@MainActor
final class GlassesLinkSignal {
    private let link: GlassesLink
    private let repository: VoiceRepository
    private let voice: HandsFreeVoice
    private var gate = LinkSignalGate()

    init(link: GlassesLink, repository: VoiceRepository, voice: HandsFreeVoice) {
        self.link = link
        self.repository = repository
        self.voice = voice
    }

    func run() async {
        for await start in link.lastStart.values {
            let microphoneOpen = voice.state.isConversation || voice.state == .recordingNote
            if gate.shouldSignal(start, microphoneOpen: microphoneOpen, nowMs: uptimeMs()) {
                await repository.signal(.glassesLinked)
            }
        }
    }
}

/// Уведомление о сбое команды с очков: сигнал сбоя пользователь уже услышал. Кнопки открывают Qanat — разрешить
/// микрофон очков в Meta AI или продолжить разговор с микрофона телефона можно только с открытого экрана.
enum VoiceFailureNotification {
    static let category = "voice_failure"
    static let identifier = "voice_failure"
    static let actionKey = "voice_notice_action"

    /// Категории с кнопками — регистрируются при запуске приложения.
    static func registerCategories() -> [UNNotificationCategory] {
        let allow = UNNotificationAction(identifier: VoiceNoticeAction.allowGlassesMicrophone.rawValue, title: L.t("voice_glasses_mic_allow"), options: .foreground)
        let phone = UNNotificationAction(identifier: VoiceNoticeAction.usePhoneMicrophone.rawValue, title: L.t("voice_glasses_mic_use_phone"), options: .foreground)
        return [
            UNNotificationCategory(identifier: category, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: category + ".allow", actions: [allow], intentIdentifiers: []),
            UNNotificationCategory(identifier: category + ".phone", actions: [phone], intentIdentifiers: []),
            UNNotificationCategory(identifier: category + ".both", actions: [allow, phone], intentIdentifiers: []),
        ]
    }

    static func show(_ notice: HandsFreeFailureNotice) {
        let content = UNMutableNotificationContent()
        content.title = L.t("voice_failure_notice_title")
        content.body = L.t(notice.messageKey)
        content.categoryIdentifier = switch (notice.allowInMetaAi, notice.continueOnPhone) {
        case (true, true): category + ".both"
        case (true, false): category + ".allow"
        case (false, true): category + ".phone"
        case (false, false): category
        }
        content.userInfo = [actionKey: VoiceNoticeAction.open.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func cancel() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
