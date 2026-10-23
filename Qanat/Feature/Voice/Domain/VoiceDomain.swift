import Foundation

enum VoiceError: Error, Equatable {
    /// Разговор шёл через очки, и они отключились.
    case glassesDisconnected
    /// Разговор шёл через очки, и их сняли.
    case glassesTakenOff
    /// Очки на связи и надеты, а звук их микрофона (поток камеры Meta SDK) не пошёл. Другой микрофон молча не берём.
    case glassesMicrophoneUnavailable(GlassesMicrophoneReason)
    /// Нет разрешения на микрофон, или его занял кто-то другой.
    case microphoneUnavailable
    /// Нужен микрофон телефона, а приложение в фоне и запись была бы тишиной. С экрана приложения она пойдёт.
    case phoneMicrophoneInBackground
    /// Нет права на голосовой режим: агент, распознавание или озвучка выключены для пользователя.
    case notAllowed
    /// Сервер не принял токен даже после обновления — нужно войти заново.
    case notSignedIn
    /// Чат удалён или принадлежит другому пользователю.
    case chatNotFound
    /// Уже открыты два голосовых разговора — больше нельзя.
    case tooManyConversations
    /// Сервер сбоил посреди разговора (закрыл его кодом 1011) и не поднял его и после переподключений.
    case kanatUnavailable(String)
    case network
    case server(String)

    var noPermission: Bool {
        if case .glassesMicrophoneUnavailable(.noPermission) = self { return true }
        return false
    }
}

enum GlassesMicrophoneReason: Equatable {
    /// Камера или микрофон очков не разрешены в Meta AI.
    case noPermission
    /// Камеру очков держит съёмка без звука — запись видео или снимок.
    case cameraBusy
    /// Поток не пошёл или оборвался.
    case failed
}

/// Ход разговора, о котором сообщает сервер.
enum ConversationEvent: Equatable {
    /// Что сейчас делает Канат.
    case kanat(KanatActivity)
    /// Вопрос (answer = false) или ответ сохранён в чат разговора — в его истории появилось новое.
    case saved(answer: Bool)
    /// Очередной шаг работы Каната над ответом.
    case trace(TraceStep)
    /// Снимок или видео дошли до Каната: он увидит их со следующей фразой — о них можно спрашивать.
    case attached
}

enum KanatActivity: Equatable { case listening, thinking, speaking }

/// Звуковые подсказки для управления без экрана.
enum VoiceSignal {
    case recordingStarted, recordingStopped, noteSent, newChat, failed
    case conversationStarted, conversationEnded
    /// Очки на связи с Qanat: сессия с ними запустилась — впервые или после переподключения.
    case glassesLinked
    /// Снимок или видео дошли до Каната в разговоре — теперь о них можно спрашивать.
    case attached
}

/// Параметры голосового разговора — см. [VoiceRepository.converse].
struct ConversationRequest {
    let chatId: String
    /// Пока истинно, микрофон продолжает писаться, но на сервер уходит тишина вместо речи.
    var muted: () -> Bool = { false }
    /// id снимков («вот, смотри»), уже загруженных на сервер, — к следующей фразе разговора.
    var photoRequests: AsyncQueue<String> = AsyncQueue()
    /// id видео с очков, уже загруженных на сервер, — к следующей фразе.
    var videoRequests: AsyncQueue<String> = AsyncQueue()
    /// Пока истинно (видео Канату снимается или грузится), минута тишины разговор не заканчивает.
    var videoPending: () -> Bool = { false }
    /// Сервер готов слушать.
    var onReady: () -> Void = {}
    /// Текст приветствия/«не расслышал» без звука в истории чата; nil — реплику перебили.
    var onSubtitle: (String?) -> Void = { _ in }
    /// Распознанное из речи пользователя по ходу фразы; final — фраза закончена и уже ушла агенту.
    var onHeard: (_ text: String, _ final: Bool) -> Void = { _, _ in }
    /// Микрофон телефона в любом случае; иначе — очков, если они на связи и надеты.
    var phoneMicrophone = false
    /// Что сервер сообщает о ходе разговора помимо звука.
    var onEvent: (ConversationEvent) -> Void = { _ in }
}

protocol VoiceRepository: AnyObject {
    /// Новый пустой чат для команд с очков. Возвращает id чата.
    func newChat() async throws -> String

    /// Голосовой разговор с Канатом: микрофон непрерывно уходит на сервер, ответы играют. Конец фразы и перебивание
    /// определяет сервер. Длится до отмены, до штатного завершения разговора сервером или до минуты молчания.
    /// Бросает [VoiceError]; glassesMicrophoneUnavailable — микрофон очков не пошёл.
    func converse(_ request: ConversationRequest) async throws

    /// Голосовое сообщение с микрофона очков (не на связи или сняты — телефона). Пишет, пока не вернётся [awaitStop],
    /// пока после речи не наступит пауза или не кончится лимит длины. Файл записи удалит [sendNote]; nil — речи не было.
    func recordNote(awaitStop: @escaping () async -> Void) async throws -> URL?

    /// Отправляет голосовое в чат, озвучивает ответ Каната и удаляет файл. [onSaved] — сервер сохранил вопрос:
    /// дальше обрыв потока или сбой озвучки — не ошибка. Бросает [VoiceError], пока вопрос не сохранён.
    func sendNote(chatId: String, note: URL, photoIds: [String], videoId: String?, onSaved: @escaping () async -> Void) async throws

    /// Короткий звуковой сигнал в очках; возвращается, когда он отзвучал.
    func signal(_ signal: VoiceSignal) async
}

/// Чат для команд с очков. Голосовые и разговоры идут в один и тот же чат, пока между командами проходит меньше часа;
/// после часа без команд или по тройному нажатию — новый чат. Час отсчитывается от конца последней команды.
@MainActor
final class HandsFreeChat {
    private let repository: VoiceRepository
    private let now: () -> Date
    private var chatId: String?
    private var lastUsedAt = Date.distantPast

    private static let sessionTimeout: TimeInterval = 60 * 60

    init(repository: VoiceRepository, now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.now = now
    }

    /// Чат для очередной команды: прежний, если он ещё свежий, иначе новый.
    func current() async throws -> String {
        let time = now()
        let id: String
        if let chatId, time.timeIntervalSince(lastUsedAt) < Self.sessionTimeout {
            id = chatId
        } else {
            id = try await repository.newChat()
        }
        chatId = id
        lastUsedAt = time
        return id
    }

    /// Команда закончилась — отсюда отсчитывается час.
    func touch() {
        if chatId != nil { lastUsedAt = now() }
    }

    /// Следующая команда начнёт новый чат.
    func startNew() { chatId = nil }

    /// Следующая команда пойдёт в чат [id], открытый на экране; nil — экран «Новый чат», и чат будет новый.
    func use(_ id: String?) {
        guard let id else { return startNew() }
        chatId = id
        lastUsedAt = now()
    }
}
