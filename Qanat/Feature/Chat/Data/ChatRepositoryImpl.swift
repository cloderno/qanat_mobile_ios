import Combine
import Foundation

final class ChatRepositoryImpl: ChatRepository {
    private let api: ApiClient
    private let answers: AgentAnswerStream
    private let updates = PassthroughSubject<String, Never>()

    init(api: ApiClient, answers: AgentAnswerStream) {
        self.api = api
        self.answers = answers
    }

    var chatUpdates: AnyPublisher<String, Never> { updates.eraseToAnyPublisher() }

    func chats(cursor: String?) async throws -> ChatPage {
        try await mapErrors {
            let page = try await json("agent/chats", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let next = page.string("next")
            return ChatPage(chats: page.objects("chats").map(AgentMappers.chat), nextCursor: next.isEmpty ? nil : next)
        }
    }

    func pinnedChats() async throws -> [Chat] {
        try await mapErrors {
            try await json("agent/chats", query: [URLQueryItem(name: "pinned", value: "true")]).objects("chats").map(AgentMappers.chat)
        }
    }

    func setPinned(id: String, pinned: Bool) async throws -> Chat {
        try await patch(id, ["pinned": pinned])
    }

    func rename(id: String, title: String) async throws -> Chat {
        try await patch(id, ["title": title.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    /// Переименовать или закрепить: полей, которых нет в [body], сервер не трогает.
    private func patch(_ id: String, _ body: [String: Any]) async throws -> Chat {
        try await mapErrors {
            var request = api.request("PATCH", "agent/chats/\(id)")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return AgentMappers.chat(try JSONValue.parse(try await api.data(request)))
        }
    }

    func deleteChat(id: String) async throws {
        do {
            try await mapErrors { _ = try await api.data(api.request("DELETE", "agent/chats/\(id)")) }
        } catch ChatError.notFound {
            // Чат уже удалили — например, на сайте: результат тот же.
            log.info("Чат \(id) уже удалён")
        }
    }

    func createChat() async throws -> Chat {
        try await mapErrors {
            var request = api.request("POST", "agent/chats")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Пустое название — агент придумает его сам по первому вопросу.
            request.httpBody = Data(#"{"title":""}"#.utf8)
            let created = AgentMappers.chat(try JSONValue.parse(try await api.data(request)))
            updates.send(created.id)
            return created
        }
    }

    func openChat(id: String) async throws -> OpenedChat {
        try await mapErrors {
            let detail = try await json("agent/chats/\(id)")
            return OpenedChat(
                chat: AgentMappers.chat(detail["chat"] ?? .null),
                history: ChatHistory(messages: detail.objects("messages").map(AgentMappers.message), hasEarlier: detail["has_more"]?.bool ?? false)
            )
        }
    }

    func earlierMessages(chatId: String, beforeMessageId: String) async throws -> ChatHistory {
        try await mapErrors {
            let page = try await json("agent/chats/\(chatId)/messages", query: [URLQueryItem(name: "before", value: beforeMessageId)])
            return ChatHistory(messages: page.objects("messages").map(AgentMappers.message), hasEarlier: page["has_more"]?.bool ?? false)
        }
    }

    func ask(chatId: String, question: String, photoIds: [String]) -> AsyncThrowingStream<AnswerEvent, Error> {
        respond(answers.ask(chatId: chatId, text: question, photoIds: photoIds), chatId: chatId)
    }

    /// Один запрос: сервер сам расшифровывает запись, сохраняет её и отвечает.
    func askByVoice(chatId: String, recording: URL, reply: String?, photoIds: [String], videoId: String?) -> AsyncThrowingStream<AnswerEvent, Error> {
        respond(answers.askByVoice(chatId: chatId, audio: recording, reply: reply, photoIds: photoIds, videoId: videoId), chatId: chatId)
    }

    func serverChatEvents() -> AsyncStream<ServerChatEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        for try await event in answers.chatEvents() {
                            if let parsed = Self.serverChatEvent(event) { continuation.yield(parsed) }
                        }
                        // Сервер закрыл поток по сроку (2 минуты) — сразу открываем новый.
                        continue
                    } catch is CancellationError {
                        break
                    } catch let error as HTTPError {
                        // 4xx (нет права «Агент», адреса нет) повтором не исправить: остаётся опрос по таймеру на экране.
                        if (400..<500).contains(error.code) && error.code != 429 {
                            log.warning("Поток изменений чатов недоступен: HTTP \(error.code)")
                            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                            break
                        }
                        log.warning("Поток изменений чатов оборвался: HTTP \(error.code)")
                    } catch {
                        if Task.isCancelled { break }
                        log.warning("Поток изменений чатов оборвался: \(error)")
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func speech(text: String) async throws -> Data {
        try await mapErrors {
            // Длиннее текст сервер не озвучивает.
            let request = try api.jsonRequest("POST", "agent/speech", body: ["text": String(text.prefix(1200))])
            return try await api.data(request)
        }
    }

    func messageAudio(messageId: String) async throws -> URL {
        try await mapErrors {
            let (file, _) = try await api.download(api.request("GET", "agent/messages/\(messageId)/audio"))
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("message-\(messageId).m4a")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }
    }

    private func respond(_ events: AsyncThrowingStream<ServerSentEvent, Error>, chatId: String) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        guard let answer = try Self.answerEvent(event) else { continue }
                        switch answer {
                        case .questionSaved, .done: updates.send(chatId)
                        default: break
                        }
                        continuation.yield(answer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.chatError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `changed` — {chat, kind: question|answer}; `trace` — {chat, item: шаг}. Прочее и без чата — nil.
    private static func serverChatEvent(_ event: ServerSentEvent) -> ServerChatEvent? {
        // Одно непонятное событие — не повод рвать поток.
        guard let payload = try? JSONValue.parse(event.data), payload.object != nil else { return nil }
        let chat = payload.string("chat")
        guard !chat.isEmpty else { return nil }
        switch event.event {
        // Незнакомый kind — тоже перечитать: что-то в чате изменилось.
        case "changed": return .changed(chatId: chat, answered: payload.string("kind") != "question")
        case "trace": return payload["item"].flatMap(AgentMappers.traceStep).map { .trace(chatId: chat, step: $0) }
        default: return nil
        }
    }

    private static func answerEvent(_ event: ServerSentEvent) throws -> AnswerEvent? {
        // Текст событий — реплики чата, в release не логируем.
        log.debug("<- \(event.event) \(event.data)")
        guard let payload = try? JSONValue.parse(event.data), payload.object != nil else { return nil }
        /// Сообщение приходит либо в поле "message", либо самим объектом события.
        func message() -> ChatMessage { AgentMappers.message(payload["message"]?.object != nil ? payload["message"]! : payload) }
        switch event.event {
        case "user": return .questionSaved(message())
        case "transcript": return .transcribed(message())
        case "filler": return .thinking(payload.string("text"))
        case "steps": return .steps(payload.array("tools").compactMap(\.stringValue))
        case "trace": return AgentMappers.traceStep(payload).map { .trace($0) }
        case "delta": return .textDelta(payload.string("text"))
        case "block": return .block(AgentMappers.block(payload["block"]?.object != nil ? payload["block"]! : payload))
        case "speech":
            return .speech(
                seq: payload["seq"]?.int ?? 0,
                text: payload.string("text"),
                audio: Data(base64Encoded: payload.string("audio")) ?? Data(),
                isFiller: payload["filler"]?.bool ?? false
            )
        case "done":
            // Речь не распознана — message отсутствует, самого ответа не будет.
            guard let chat = payload["chat"], chat.object != nil else { throw ChatError.server("Неожиданный ответ сервера") }
            return .done(message: payload["message"]?.object != nil ? AgentMappers.message(payload["message"]!) : nil, chat: AgentMappers.chat(chat))
        case "error":
            // error относится к одному вопросу — разговор/чат продолжается.
            var detail = payload.string("detail")
            if detail.isEmpty { detail = payload.string("message") }
            throw ChatError.server(detail.isEmpty ? event.data : detail)
        default:
            return nil
        }
    }

    private func json(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try JSONValue.parse(try await api.data(api.request("GET", path, query: query)))
    }

    private func mapErrors<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch {
            throw Self.chatError(error)
        }
    }

    static func chatError(_ error: Error) -> Error {
        switch error {
        case is ChatError, is CancellationError: return error
        case let http as HTTPError:
            switch http.code {
            case 403: return ChatError.notAllowed
            case 404: return ChatError.notFound
            default: return ChatError.server("HTTP \(http.code)")
            }
        case let url as URLError where url.code == .cancelled: return CancellationError()
        case is URLError: return ChatError.network
        case is DecodingError, is UnexpectedResponseError: return ChatError.server("Неожиданный ответ сервера")
        default: return error
        }
    }
}

private let log = Log("ChatRepository")
