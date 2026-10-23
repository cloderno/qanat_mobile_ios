import UIKit

struct ChatUiState {
    /// Список в шторке пачками, последние сверху; закреплённые в нём тоже есть — показывает их [recentChats].
    var chats: [Chat] = []
    /// Раздел «Закреплённые» над недавними, последние закреплённые сверху.
    var pinnedChats: [Chat] = []
    /// nil — новый чат: на сервере он появится с первым вопросом.
    var chat: Chat?
    var messages: [ChatMessage] = []
    var hasEarlier = false
    var isOpening = false
    /// Потянули шторку со списком чатов вниз, чтобы обновить его.
    var isRefreshingChats = false
    /// Потянули список сообщений открытого чата вниз, чтобы обновить его.
    var isRefreshingMessages = false
    /// Ответ агента, который сейчас печатается; nil — агент не отвечает.
    var answer: PendingAnswer?
    /// Ответ, который пишется по вопросу с другого устройства: «Работаю…» и шаги; nil — такого нет.
    var remoteWork: LiveTrace?
    var input = ""
    var voiceInput: VoiceInput = .none
    /// Снимок к следующему вопросу; уйдёт и с текстом, и с голосовым.
    var attachedPhoto: UIImage?
    /// Голосовое, которое сейчас звучит.
    var playing: VoiceClip?
    /// Документ, файл которого сейчас скачивается; nil — ничего не скачивается.
    var downloadingDocument: String?
    /// Скачанный файл: экран открывает его один раз и сообщает об этом; nil — открывать нечего.
    var documentToOpen: SavedDocument?
    var errorKey: String?
    /// Сообщение об успехе там же, где ошибки, но не красным: «Шаблон сохранён». Ошибка его заслоняет.
    var noticeKey: String?
    /// Поле ввода надо сфокусировать с курсором в конце текста — экран делает это один раз и сообщает об этом.
    var focusInput = false
    /// Имя и инициалы для строки профиля в шторке; nil — ещё не загружено.
    var profileName: String?
    var profileInitials = ""
    var profileAvatarURL: String?
    /// Имя и отчество для приветствия в новом чате; nil — ещё не загружено.
    var greetingName: String?
    var glassesInfo: GlassesDeviceInfo?

    /// «Недавние»: закреплённые уже показаны над ними.
    var recentChats: [Chat] { chats.filter { !$0.pinned } }

    var canSend: Bool {
        guard answer == nil, !isOpening else { return false }
        switch voiceInput {
        // Со снимком вопрос можно не писать — сервер спросит «Что на снимке?».
        case .none: return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedPhoto != nil
        case .recording: return false
        case .ready: return true
        }
    }

    /// Чат [updated] — переименованный или (от)креплённый — на своих местах: в открытом чате и в обоих разделах шторки.
    /// Только что закреплённый встаёт наверх «Закреплённых», откреплённый возвращается в «Недавние» по времени.
    func withUpdatedChat(_ updated: Chat) -> ChatUiState {
        let wasPinned = pinnedChats.contains { $0.id == updated.id }
        let pinned: [Chat] = if !updated.pinned {
            pinnedChats.filter { $0.id != updated.id }
        } else if wasPinned {
            pinnedChats.map { $0.id == updated.id ? updated : $0 }
        } else {
            [updated] + pinnedChats
        }
        let recent: [Chat] = if chats.contains(where: { $0.id == updated.id }) {
            chats.map { $0.id == updated.id ? updated : $0 }
        } else {
            // Чата не было в загруженных пачках — откреплённый встаёт к недавним по времени последнего сообщения.
            (chats + [updated]).sorted { $0.updatedAt > $1.updatedAt }
        }
        var copy = self
        if chat?.id == updated.id { copy.chat = updated }
        copy.chats = recent
        copy.pinnedChats = pinned
        return copy
    }

    /// Можно ли сейчас сверяться в фоне. Не мешаем своему ответу, пока он идёт потоком, и открытию чата.
    func shouldSyncInBackground(answerInFlight: Bool) -> Bool {
        !answerInFlight && !isOpening && !isRefreshingMessages
    }
}

/// Голосовое в поле ввода: идёт запись, или запись готова — её можно прослушать и отправить вместо текста.
enum VoiceInput: Equatable {
    case none
    case recording
    case ready(VoiceRecording)
}

struct PendingAnswer: Equatable {
    var text = ""
    var blocks: [ChatBlock] = []
    /// «Секунду, посмотрю…», пока не пошёл текст.
    var status = ""
    /// Инструменты, которые агент уже вызвал, — по ним строка «Смотрю поручения…».
    var steps: [String] = []
    /// Ход работы, по шагу; есть — показывается вместо строки по [steps].
    var trace: [TraceStep] = []
}
