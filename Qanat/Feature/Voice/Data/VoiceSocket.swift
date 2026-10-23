import Foundation

/// Что приходит в плеер: звук ответа и команды для него — пауза, продолжение, выбросить недоигранное.
enum Playback {
    case chunk(Data)
    /// Пользователь перебил Каната — старый ответ больше не нужен, как и пауза перед этим.
    case interrupt
    /// Пользователь заговорил поверх ответа: звук на паузу, а недоигранное и то, что ещё придёт, ждут [resume].
    case pause
    /// Реплика на паузе была не Канату — ответ звучит дальше с того же места.
    case resume
    /// Реплика без звука в истории: приветствие или «не расслышал» — показывается субтитром.
    case subtitle(String)
    /// Распознанное по ходу речи пользователя: [final] — фраза закончена и ушла агенту, иначе ещё копится.
    case heard(String, final: Bool)

    /// Что делает Канат, судя по событию плеера; nil — событие этого не меняет.
    var kanatActivity: KanatActivity? {
        switch self {
        case .chunk, .resume: .speaking
        case .heard(let text, let final): final && !text.isEmpty ? .thinking : nil
        case .interrupt, .pause: .listening
        case .subtitle: nil
        }
    }
}

/// Голосовой режим сервера: `wss://<host>/realtime/voice?chat=<id>`. Звук в обе стороны — бинарные кадры PCM,
/// конец фразы и перебивание определяет сервер. Текстовые кадры — JSON с полем "type".
/// Сервер проверяет токен уже после рукопожатия и закрывает сокет кодом 4401, поэтому токен обновляем здесь
/// и переподключаемся один раз.
final class VoiceSocket {
    private let tokenStorage: TokenStorage
    private let authenticator: TokenAuthenticator
    private let url: URL
    private let session = URLSession(configuration: .default)

    init(tokenStorage: TokenStorage, authenticator: TokenAuthenticator, baseURL: URL = AppConfig.baseURL) {
        self.tokenStorage = tokenStorage
        self.authenticator = authenticator
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/realtime/voice"
        components.query = nil
        url = components.url!
    }

    /// Разговор в чате [chatId]. Возвращается, когда сервер прислал "ready" и готов слушать.
    /// [vision] — Канату можно смотреть через камеру очков: сервер будет присылать запросы [VoiceConnection.looks].
    func open(chatId: String, vision: Bool) async throws -> VoiceConnection {
        guard let accessToken = tokenStorage.current()?.accessToken else { throw VoiceError.notSignedIn }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "chat", value: chatId)] + (vision ? [URLQueryItem(name: "vision", value: "1")] : [])
        let chatURL = components.url!
        do {
            return try await connect(chatURL, token: accessToken)
        } catch is TokenRejected {
            // nil — refresh отвергнут и сессия очищена (приложение уйдёт на логин) или его не удалось разобрать.
            guard let refreshed = await authenticator.refresh(failedAccessToken: accessToken) else { throw VoiceError.notSignedIn }
            do {
                return try await connect(chatURL, token: refreshed.accessToken)
            } catch is TokenRejected {
                throw VoiceError.notSignedIn
            }
        }
    }

    private func connect(_ chatURL: URL, token: String) async throws -> VoiceConnection {
        var request = URLRequest(url: chatURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        let connection = VoiceConnection(task: task)
        task.resume()
        connection.startReceiving()
        do {
            try await connection.awaitReady()
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
        return connection
    }
}

/// Сервер отверг access-токен — его можно обновить и подключиться заново.
struct TokenRejected: Error {}

private enum CloseCode {
    static let normal = 1000
    static let serverFailure = 1011
    static let tokenRejected = 4401
    static let notAllowed = 4403
    static let chatNotFound = 4404
    static let superseded = 4409
    static let hourLimit = 4410
    static let tooManyConversations = 4429
    // 4408 — от телефона 120 с ничего не приходило: переподключаться незачем, это ошибка.
}

final class VoiceConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    /// Звук от сервера и команды плееру — очередь: плеер забирает их, не дожидаясь, пока доиграет звук.
    /// Закрывается, когда сервер штатно закрыл разговор, а при ошибке — с [VoiceError].
    let audio = AsyncQueue<Playback>()
    /// id запросов «посмотри» — на каждый нужен [answerLook]. Отдельно от звука: "interrupted" выбрасывает очередь звука.
    let looks = AsyncQueue<JSONValue>()
    /// Что делает Канат и что легло в историю чата; заканчивается вместе с разговором.
    let events = AsyncQueue<ConversationEvent>()

    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResult: Result<Void, Error>?
    private var endedByServer = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, Error>? = lock.withLock {
                if let readyResult { return readyResult }
                readyContinuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    private func completeReady(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard readyResult == nil else { return nil }
            readyResult = result
            defer { readyContinuation = nil }
            return readyContinuation
        }
        continuation?.resume(with: result)
    }

    func startReceiving() {
        Task { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .data(let data): audio.send(.chunk(data))
                    case .string(let text): handle(text)
                    @unknown default: break
                    }
                } catch {
                    closed(error)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        log.debug("<- \(text)")
        guard let frame = try? JSONValue.parse(text), frame.object != nil else { return }
        switch frame.string("type") {
        case "ready":
            completeReady(.success(()))
        // Сервер прекратил ответ, потому что пользователь заговорил: выбрасываем то, что плеер не успел забрать,
        // а он сам сбрасывает свою очередь и паузу.
        case "interrupted":
            audio.clearPending()
            audio.send(.interrupt)
        // Пользователь заговорил поверх ответа, и сервер решает, Канату ли это: звук на паузу.
        case "pause":
            audio.send(.pause)
        // Это было не Канату: ответ звучит дальше, а распознанное на паузе — не вопрос.
        case "resume":
            audio.send(.heard("", final: false))
            audio.send(.resume)
        // Приветствие при входе в разговор или «не расслышал» — звук идёт следом обычными кадрами.
        case "greeting", "not_heard":
            if let subtitle = frame["text"]?.stringValue { audio.send(.subtitle(subtitle)) }
        // Распознано по ходу речи: текст каждый раз целиком, не дельта.
        case "heard":
            if let heard = frame["text"]?.stringValue { audio.send(.heard(heard, final: frame.string("final") == "true")) }
        // Канату нужно посмотреть: id возвращаем ровно таким, каким он пришёл.
        case "look":
            if let id = frame["id"] { looks.send(id) }
        case "state":
            let activity: KanatActivity? = switch frame.string("state") {
            case "listening": .listening
            case "thinking": .thinking
            case "speaking": .speaking
            default: nil
            }
            if let activity { events.send(.kanat(activity)) }
        case "user": events.send(.saved(answer: false))
        case "done": events.send(.saved(answer: true))
        // Что Канат делает над ответом: шаг целиком в самом кадре, рядом с "type".
        case "trace":
            if let step = AgentMappers.traceStep(frame) { events.send(.trace(step)) }
        case "attached": events.send(.attached)
        // «Ответа на эту фразу не будет» — сервер сам голосом извинится и слушает дальше.
        case "error": log.debug("Без ответа на фразу: \(frame.string("detail"))")
        default: break
        }
    }

    /// Соединение закрыто сервером или оборвалось. Коды закрытия — см. [CloseCode].
    private func closed(_ error: Error) {
        let code = task.closeCode.rawValue
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if code != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            // Причина — служебный текст сервера по-английски, реплик чата в ней нет: пишем и в release.
            log.info("Сервер закрыл разговор: \(code) \(reason)")
            lock.withLock { endedByServer = true }
        }
        func fail(_ voiceError: Error) {
            completeReady(.failure(voiceError))
            audio.finish(throwing: voiceError)
        }
        switch code {
        case CloseCode.tokenRejected:
            completeReady(.failure(TokenRejected()))
            audio.finish(throwing: VoiceError.notSignedIn)
        // Тот же чат открыли новым соединением — это не ошибка, старое просто вытеснили.
        case CloseCode.superseded:
            completeReady(.success(()))
            audio.finish()
        case CloseCode.notAllowed: fail(VoiceError.notAllowed)
        case CloseCode.chatNotFound: fail(VoiceError.chatNotFound)
        case CloseCode.tooManyConversations: fail(VoiceError.tooManyConversations)
        // Сбой на сервере — к тому же чату можно переподключиться, разговор продолжится.
        case CloseCode.serverFailure: fail(VoiceError.kanatUnavailable("Сервер сбоил: \(reason)"))
        // Разговор длится час — сервер закрывает его, но человек ещё говорит: переподключаемся, как при обрыве.
        case CloseCode.hourLimit: fail(VoiceError.network)
        case CloseCode.normal:
            completeReady(.failure(VoiceError.server("Сервер закрыл соединение до ready")))
            audio.finish()
        case URLSessionWebSocketTask.CloseCode.invalid.rawValue:
            // Рукопожатие отклонено (403) или сеть оборвалась.
            let status = (task.response as? HTTPURLResponse)?.statusCode
            log.debug("failure \(String(describing: status)): \(error)")
            fail(status == 403 ? VoiceError.notAllowed : VoiceError.network)
        default:
            fail(VoiceError.server("Сервер закрыл соединение: \(code) \(reason)"))
        }
        looks.finish()
        events.finish()
    }

    /// Если разговор закрыл сервер, микрофон просто больше не нужен: чем всё кончилось, скажет [audio].
    /// Иначе неотправленный звук — обрыв связи.
    func sendAudio(_ pcm: Data) async throws {
        do {
            try await task.send(.data(pcm))
        } catch {
            if lock.withLock({ endedByServer }) { return }
            throw VoiceError.network
        }
    }

    /// Ответ на запрос «посмотри» [id]: [photoId] — снимок, уже загруженный на сервер; nil — посмотреть нельзя.
    func answerLook(id: JSONValue, photoId: String?) {
        var answer = #"{"type":"look","id":"# + id.jsonString
        if let photoId {
            answer += #","photo":"# + JSONValue.string(photoId).jsonString
        } else {
            answer += #","error":"unavailable""#
        }
        sendText(answer + "}")
    }

    /// Отдельный «вот, смотри» снимок — сервер прикладывает его к следующей фразе и подтверждает "attached".
    func sendPhoto(_ photoId: String) {
        sendText(#"{"type":"photo","id":"# + JSONValue.string(photoId).jsonString + "}")
    }

    /// Живой кадр с камеры очков: сервер держит самый свежий и прикладывает его к следующей законченной фразе.
    func sendFrame(_ jpeg: Data) {
        sendText(#"{"type":"frame","jpeg":""# + jpeg.base64EncodedString() + #""}"#)
    }

    /// Живых кадров больше не будет: сервер забывает последний и, если Канату надо посмотреть, просит снимок.
    func sendCameraOff() {
        sendText(#"{"type":"camera","on":false}"#)
    }

    /// Видео с очков, уже загруженное на сервер, — к следующей фразе. false — соединение уже закрывается.
    func sendVideo(_ videoId: String) async -> Bool {
        do {
            try await task.send(.string(#"{"type":"video","id":"# + JSONValue.string(videoId).jsonString + "}"))
            return true
        } catch {
            return false
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func sendText(_ text: String) {
        task.send(.string(text)) { error in
            if let error { log.debug("Кадр не ушёл: \(error)") }
        }
    }
}

private let log = Log("VoiceSocket")
