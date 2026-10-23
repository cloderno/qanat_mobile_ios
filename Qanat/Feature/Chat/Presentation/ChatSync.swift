import Foundation

/*
 * Фоновая сверка с сервером, как на сайте: пока экран чата виден, список чатов и открытый чат перечитываются,
 * как только сервер сообщит об изменении (и изредка по таймеру) — вопросы и ответы с сайта, голосом и с очков,
 * дописанные сервером дашборды и презентации появляются без ручного обновления.
 */

/// Вопрос, который сервер ещё не сохранил и не выдал ему UUID.
let localQuestionId = "local-question"

/// Снимок такого вопроса: на сервере его ещё нет, в ленте на его месте пустая плитка.
let localPhotoId = "local-photo"

/// Последние сообщения чата [latest] с сервера поверх того, что уже в ленте [current]: подгруженная раньше история
/// остаётся, если с ней есть стык, повторов нет. Неотправленный вопрос остаётся внизу, пока сервер не прислал новый
/// вопрос — значит, это он и есть.
func mergeLatestMessages(current: [ChatMessage], currentHasEarlier: Bool, latest: ChatHistory) -> ChatHistory {
    let local = current.filter { $0.id == localQuestionId }
    let saved = current.filter { $0.id != localQuestionId }
    let known = Set(saved.map(\.id))
    let serverHasNewQuestion = latest.messages.contains { $0.role == .user && !known.contains($0.id) }
    let pending = serverHasNewQuestion ? [] : local

    // Без стыка неизвестно, нет ли между ними пропуска, — тогда история начинается с того, что прислал сервер.
    let anchor = latest.messages.first.flatMap { first in saved.firstIndex { $0.id == first.id } } ?? -1
    let older = anchor > 0 ? Array(saved[0..<anchor]) : []
    var seen = Set<String>()
    let merged = (older + latest.messages).filter { seen.insert($0.id).inserted }
    return ChatHistory(messages: merged + pending, hasEarlier: older.isEmpty ? latest.hasEarlier : currentHasEarlier)
}

/// Свежая первая пачка списка чатов вместо начала [current]. Догруженные прокруткой старые чаты остаются,
/// если дальше есть ещё пачки ([hasMore]); без них первая пачка — это весь список.
func mergeFirstChatPage(current: [Chat], firstPage: [Chat], hasMore: Bool) -> [Chat] {
    guard hasMore, let oldest = firstPage.last?.updatedAt else { return firstPage }
    let ids = Set(firstPage.map(\.id))
    return firstPage + current.filter { !ids.contains($0.id) && $0.updatedAt <= oldest }
}

extension ChatHistory {
    /// Ответ агента уже в ленте: последнее сообщение — от него.
    var endsWithAnswer: Bool { messages.last?.role == .assistant }
}

/// Сколько секунд работал агент: по [latencyMs], иначе по последнему шагу; не меньше 1. nil — неизвестно.
func workedSeconds(latencyMs: Int64?, trace: [TraceStep]) -> Int64? {
    guard let ms = latencyMs ?? trace.compactMap(\.atMs).max() else { return nil }
    return max(Int64((Double(ms) / 1000).rounded()), 1)
}
