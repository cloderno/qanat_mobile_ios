import Foundation

/// Одно событие потока text/event-stream: `event:` и склеенные строки `data:`.
struct ServerSentEvent: Equatable {
    let event: String
    let data: String
}

/// Вопрос агенту: POST, ответ на который — поток SSE. Токен и его обновление — от общего клиента.
final class AgentAnswerStream {
    private let api: ApiClient
    /// Агент может думать дольше стандартного таймаута между событиями.
    private let session: URLSession

    init(api: ApiClient) {
        self.api = api
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        session = URLSession(configuration: configuration)
    }

    /// Мобильный адрес: в отличие от общего /agent/, принимает снимки.
    func ask(chatId: String, text: String, photoIds: [String]) -> AsyncThrowingStream<ServerSentEvent, Error> {
        stream {
            var body: [String: Any] = ["text": text]
            if !photoIds.isEmpty { body["photos"] = photoIds }
            var request = self.api.request("POST", "mobile/agent/chats/\(chatId)/messages")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    /// Голосовой вопрос одним запросом: сервер сам расшифровывает, сохраняет и отвечает.
    func askByVoice(chatId: String, audio: URL, reply: String?, photoIds: [String], videoId: String?) -> AsyncThrowingStream<ServerSentEvent, Error> {
        stream {
            var form = MultipartForm()
            form.addFile(name: "audio", filename: audio.lastPathComponent, mimeType: "audio/mp4", data: try Data(contentsOf: audio))
            if let reply { form.addField(name: "reply", value: reply) }
            if !photoIds.isEmpty { form.addField(name: "photos", value: photoIds.joined(separator: ",")) }
            if let videoId { form.addField(name: "videos", value: videoId) }
            return form.request(self.api.request("POST", "mobile/agent/chats/\(chatId)/voice"))
        }
    }

    /// Чаты, изменившиеся на сервере с любого устройства: `changed` с `{"chat","kind"}` и `: ping` раз в ~15 с.
    /// Сервер закрывает поток через 2 минуты — тогда поток просто кончается; переподключение за вызывающим.
    func chatEvents() -> AsyncThrowingStream<ServerSentEvent, Error> {
        stream { self.api.request("GET", "agent/events") }
    }

    private func stream(_ makeRequest: @escaping () throws -> URLRequest) -> AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest()
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 3 * 60
                    let (bytes, _) = try await api.bytes(request)
                    var event = "message"
                    var data = ""
                    // lines пропускает пустые строки, а они разделяют события — поэтому строки собираем сами.
                    var line = Data()
                    func handle(_ raw: String) {
                        if raw.isEmpty {
                            if !data.isEmpty { continuation.yield(ServerSentEvent(event: event, data: data)) }
                            event = "message"
                            data = ""
                        } else if raw.hasPrefix("event:") {
                            event = raw.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if raw.hasPrefix("data:") {
                            var value = raw.dropFirst(5)
                            if value.hasPrefix(" ") { value = value.dropFirst() }
                            if !data.isEmpty { data += "\n" }
                            data += value
                        }
                        // Строки-комментарии (`:`) и id: не нужны.
                    }
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            var text = String(decoding: line, as: UTF8.self)
                            if text.hasSuffix("\r") { text.removeLast() }
                            handle(text)
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { handle(String(decoding: line, as: UTF8.self)) }
                    handle("")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Отмена (ушли из чата) прерывает чтение; сервер всё равно допишет ответ.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
