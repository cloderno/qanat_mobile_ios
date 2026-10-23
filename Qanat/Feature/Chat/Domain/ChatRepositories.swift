import Combine
import Foundation

/// Чаты с агентом Каната. Все методы бросают [ChatError].
protocol ChatRepository: AnyObject {
    /// Чаты, последние сверху; [cursor] — из [ChatPage.nextCursor] прошлой пачки, nil — с начала.
    func chats(cursor: String?) async throws -> ChatPage

    /// Закреплённые чаты — все сразу, последние закреплённые сверху.
    func pinnedChats() async throws -> [Chat]

    /// Закрепляет или открепляет чат. Возвращает чат с новым [Chat.pinned].
    func setPinned(id: String, pinned: Bool) async throws -> Chat

    /// Новое название чата.
    func rename(id: String, title: String) async throws -> Chat

    /// Удаляет чат вместе с его сообщениями. Уже удалённый — не ошибка.
    func deleteChat(id: String) async throws

    /// Пустой чат; название агент придумает по первому вопросу.
    func createChat() async throws -> Chat

    /// Чат и его последние сообщения.
    func openChat(id: String) async throws -> OpenedChat

    /// Сообщения раньше [beforeMessageId] — подгрузка при прокрутке вверх.
    func earlierMessages(chatId: String, beforeMessageId: String) async throws -> ChatHistory

    /// Вопрос агенту; ответ приходит потоком событий и заканчивается [AnswerEvent.done].
    /// [photoIds] — снимки из [PhotoRepository] (до 4); со снимком вопрос может быть пустым.
    func ask(chatId: String, question: String, photoIds: [String]) -> AsyncThrowingStream<AnswerEvent, Error>

    /// Голосовой вопрос: запись сохраняется на сервере и слышна в истории, ответ — как у [ask].
    /// [reply] = "voice" — ответ агента тоже голосом. [videoId] — видео из [VideoRepository].
    func askByVoice(chatId: String, recording: URL, reply: String?, photoIds: [String], videoId: String?) -> AsyncThrowingStream<AnswerEvent, Error>

    /// Текст голосом Каната, mp3 — чтобы озвучить ответ, у которого нет своей записи.
    func speech(text: String) async throws -> Data

    /// Запись голосового вопроса [messageId], чтобы прослушать.
    func messageAudio(messageId: String) async throws -> URL

    /// Что происходит в чатах на сервере — с любого устройства, голосом, с очков. Переподключается сам,
    /// пока поток не отменят; бесконечен.
    func serverChatEvents() -> AsyncStream<ServerChatEvent>

    /// Оповещает об обновлении чата (сохранение сообщения, ответ агента, создание чата).
    var chatUpdates: AnyPublisher<String, Never> { get }
}

/// Документ, который агент сделал пользователю, — из вкладки «Документы».
struct AgentDocument: Equatable, Identifiable {
    /// [other] — вид, которого приложение пока не знает: в списке он есть, в фильтре — нет.
    enum Kind: String, CaseIterable { case deck, dashboard, letter, other }

    let id: String
    let kind: Kind
    let title: String
    /// «6 слайдов», период дашборда, адресат письма; пусто — подписи нет.
    let subtitle: String
    /// Чат, где документ сделан; nil — чат удалён.
    let chatId: String?
    /// Название этого чата; пусто — агент его не придумал.
    let chatTitle: String
    let createdAt: Date
    /// Сам документ — тот же блок, что в ответе агента.
    let block: ChatBlock
    /// Файлы, которые можно скачать; пусто — документ только для просмотра (дашборд).
    let formats: [DocumentFormat]
}

/// Файл документа: письмо — Word, презентация — PowerPoint или страница HTML.
enum DocumentFormat: String, CaseIterable { case docx, pptx, html }

/// Пачка документов, новые сверху; [nextCursor] — для следующей пачки, nil — документов больше нет.
struct DocumentPage: Equatable {
    let documents: [AgentDocument]
    let nextCursor: String?
}

/// Шаблон письма — сохранённое письмо, по которому агент пишет новые.
struct LetterTemplate: Equatable, Identifiable {
    let id: String
    let name: String
    let kindLabel: String
    let subject: String
    let addresseeShort: String
    let createdAt: Date
    /// Когда по нему писали последний раз; nil — ещё не писали.
    let usedAt: Date?
}

/// Скачанный файл: [url] — его адрес на телефоне, по нему файл открывают другие приложения.
struct SavedDocument: Equatable {
    let url: URL
    let mimeType: String
    let fileName: String
}

/// Документы, которые подготовил агент: презентации, дашборды, письма. Все методы бросают [ChatError].
protocol DocumentRepository: AnyObject {
    /// Документы, новые сверху. [kind] — только этого вида, nil — все; [query] — поиск по названию.
    func documents(kind: AgentDocument.Kind?, query: String, cursor: String?) async throws -> DocumentPage

    func document(id: String) async throws -> AgentDocument

    /// Скачивает файл документа. Презентация скачивается на языке приложения.
    func download(id: String, format: DocumentFormat) async throws -> SavedDocument

    /// Убирает документ из «Документов» — в чате его блок остаётся. Уже убранный — не ошибка.
    func delete(id: String) async throws

    /// Сохраняет письмо [documentId] шаблоном [name]; шаблон с тем же названием заменяется.
    func saveAsTemplate(documentId: String, name: String) async throws -> LetterTemplate

    /// Шаблоны писем пользователя, по названию.
    func letterTemplates() async throws -> [LetterTemplate]

    /// Удаляет шаблон; уже удалённый — не ошибка.
    func deleteLetterTemplate(id: String) async throws

    /// id документов, убранных через [delete], — чтобы убрать их и из уже показанных списков.
    var deleted: AnyPublisher<String, Never> { get }
}

/// Снимок, прикладываемый к вопросу агенту.
protocol PhotoRepository: AnyObject {
    /// Загружает снимок на сервер. Возвращает его UUID.
    func upload(jpeg: Data, source: PhotoSource) async throws -> String

    /// JPEG снимка с сервера: [thumbnail] — плитка до 400 px, иначе весь снимок.
    func photo(id: String, thumbnail: Bool) async throws -> Data

    /// Удаляет снимок на сервере — и из вопроса, к которому он приложен. Уже удалённый — не ошибка.
    func delete(id: String) async throws
}

enum PhotoSource: String { case phone, glasses }

/// Видео с очков, прикладываемое к вопросу Канату: в голосовое или в разговор.
protocol VideoRepository: AnyObject {
    /// Загружает видео (MP4) на сервер. Возвращает его UUID.
    func upload(video: URL) async throws -> String

    /// Удаляет видео на сервере. Уже удалённое — не ошибка.
    func delete(id: String) async throws
}

/// Сколько может идти загрузка видео: мегабайты по мобильной сети. Столько же голосовое ждёт своё видео.
let videoUploadTimeoutSeconds: Double = 180

/// Голосовое сообщение, записанное, но ещё не отправленное.
struct VoiceRecording: Equatable {
    let file: URL
    let durationMs: Int64
}

/// Запись голосового сообщения с микрофона.
protocol VoiceNoteRecorder: AnyObject {
    /// Бросает [ChatError.microphoneUnavailable].
    func start() throws
    /// nil — записать ничего не успели. Файл удаляет тот, кто его получил.
    func stop() -> VoiceRecording?
    /// Прервать запись и выбросить её.
    func cancel()
    /// Громкость 0…1 — для волны под записью.
    var level: Float { get }
}

/// Что можно прослушать: ещё не отправленную запись, голосовое из истории или озвученный ответ.
enum VoiceClip: Equatable {
    case draft(URL)
    case message(messageId: String)
    /// Ответ [messageId] без своей записи — [text] озвучивает сервер голосом Каната.
    case speech(messageId: String, text: String)
}

protocol VoicePlayer: AnyObject {
    /// Что сейчас играет; nil — ничего.
    var playing: CurrentValueSubject<VoiceClip?, Never> { get }
    /// Включает [clip], останавливая предыдущий; если [clip] уже играет — останавливает его.
    func toggle(_ clip: VoiceClip) async
    func stop()
}
