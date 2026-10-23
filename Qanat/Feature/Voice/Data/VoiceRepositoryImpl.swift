import Combine
import Foundation

/// Чей микрофон слушает голосовой режим. Bluetooth-гарнитуры (HFP) среди них нет.
enum MicrophoneSource {
    /// Микрофон очков через поток камеры Meta SDK (PCM 16 кГц моно); на очках мигает индикатор камеры.
    case glasses
    /// Микрофон телефона.
    case phone
}

/// Очки на связи и надеты — слушаем их микрофон, иначе — телефон. Очки без датчика ношения снятыми не считаем.
func microphoneSource(_ glasses: GlassesDeviceInfo?) -> MicrophoneSource {
    glasses?.isConnected == true && glasses?.isWorn != false ? .glasses : .phone
}

/// «Посмотри» в разговоре: камера очков включается на один снимок — на очках индикатор вспыхивает один раз.
/// Снимок остаётся и в галерее очков, как снятый кнопкой.
final class GlassesLook {
    private let preferencesStorage: PreferencesStorage
    private let glasses: GlassesControls
    private let camera: GlassesCamera
    private let photos: PhotoRepository
    private let media: GlassesMediaRepository

    init(preferencesStorage: PreferencesStorage, glasses: GlassesControls, camera: GlassesCamera, photos: PhotoRepository, media: GlassesMediaRepository) {
        self.preferencesStorage = preferencesStorage
        self.glasses = glasses
        self.camera = camera
        self.photos = photos
        self.media = media
    }

    /// Снимок с очков для Каната. Возвращает UUID загруженного снимка; nil — посмотреть нельзя.
    func take() async -> String? {
        // Зрение могли выключить, а очки снять уже во время разговора — тогда отказываем сразу, без камеры.
        guard preferencesStorage.current().glassesVision, glasses.currentDeviceInfo?.isWorn != false else { return nil }
        let photo: Data
        do {
            photo = try await camera.capturePhoto(full: true)
        } catch {
            log.warning("Канат не смог посмотреть через очки: \(error)")
            return nil
        }
        // Сохранение идёт рядом с загрузкой: ответа Каната ждут, а галерея подождёт.
        async let saved = try? media.savePhoto(photo)
        let photoId = try? await photos.upload(jpeg: photo, source: .glasses)
        if let item = await saved, let photoId { await media.rememberServerCopy(item, serverId: photoId) }
        return photoId
    }
}

/// Голосовые сообщения уходят в чаты через [ChatRepository] — явный контракт фичи chat.
final class VoiceRepositoryImpl: VoiceRepository {
    private let recorder: PcmRecorder
    private let player: PcmPlayer
    private let noteRecorder: NoteRecorder
    private let datNotes: DatNoteRecorder
    private let glassesMicrophone: GlassesConversationMicrophone
    private let audioPermissionPrompt: GlassesAudioPermissionPrompt
    private let signals: SignalPlayer
    private let tones: TonePlayer
    private let speech: SpeechPlayer
    private let socket: VoiceSocket
    private let glasses: GlassesControls
    private let look: GlassesLook
    private let chats: ChatRepository
    private let preferencesStorage: PreferencesStorage

    private static let idleTimeoutMs: Int64 = 60_000
    /** Как скоро после конца ответа статус в чате сменится на «слушаю». */
    private static let kanatPollMs: Int64 = 250
    private static let echoLogWindowMs: Int64 = 5_000
    /// Сколько после куска ответа его звук ещё может идти из динамиков очков.
    private static let echoTailMs: Int64 = 500
    /// Переподключение к тому же чату при обрыве сети — 1, 2, 4 с, не больше 3 попыток подряд.
    private static let reconnectDelays: [Double] = [1, 2, 4]
    /// Живой кадр Канату — раз в секунду: так ждёт сервер.
    private static let liveFrameIntervalMs: Int64 = 1_000
    /// После сбоя сервера (1011) — не больше 2 переподключений за разговор: так советует сервер.
    private static let serverFailureReconnects = 2
    // ПРЕДПОЛОЖЕНИЕ: порог не замерен на очках, а от него зависит выход по минуте тишины.
    private static let speechAmplitude = 1_500

    init(
        recorder: PcmRecorder,
        player: PcmPlayer,
        noteRecorder: NoteRecorder,
        datNotes: DatNoteRecorder,
        glassesMicrophone: GlassesConversationMicrophone,
        audioPermissionPrompt: GlassesAudioPermissionPrompt,
        signals: SignalPlayer,
        tones: TonePlayer,
        speech: SpeechPlayer,
        socket: VoiceSocket,
        glasses: GlassesControls,
        look: GlassesLook,
        chats: ChatRepository,
        preferencesStorage: PreferencesStorage
    ) {
        self.recorder = recorder
        self.player = player
        self.noteRecorder = noteRecorder
        self.datNotes = datNotes
        self.glassesMicrophone = glassesMicrophone
        self.audioPermissionPrompt = audioPermissionPrompt
        self.signals = signals
        self.tones = tones
        self.speech = speech
        self.socket = socket
        self.glasses = glasses
        self.look = look
        self.chats = chats
        self.preferencesStorage = preferencesStorage
    }

    func newChat() async throws -> String {
        try await mapChatErrors { try await self.chats.createChat().id }
    }

    func converse(_ request: ConversationRequest) async throws {
        let source = request.phoneMicrophone ? MicrophoneSource.phone : microphoneSource(glasses.currentDeviceInfo)
        log.info("Разговор: микрофон \(source)\(request.phoneMicrophone ? " по выбору пользователя" : "")")
        let conversation = Conversation(repository: self, request: request)
        switch source {
        case .phone:
            // Громкая связь с эхоподавлением — на весь разговор, через переподключения.
            try AudioSessionCoordinator.shared.activate(.conversation)
            defer { AudioSessionCoordinator.shared.deactivate(.conversation) }
            try await withReconnects(request.onReady) { onConnected in
                try await conversation.run(microphone: nil, onConnected: onConnected)
            }
        case .glasses:
            // Поток камеры со звуком включаем один раз на весь разговор. Звук ответа — в динамики очков (Bluetooth).
            do {
                try AudioSessionCoordinator.shared.activate(.playback)
                defer { AudioSessionCoordinator.shared.deactivate(.playback) }
                try await glassesMicrophone.use { microphone in
                    try await withReconnects(request.onReady) { onConnected in
                        try await conversation.run(microphone: microphone, onConnected: onConnected)
                    }
                }
            } catch let error as VoiceError where error.noPermission {
                audioPermissionPrompt.request()
                throw error
            }
        }
    }

    /// Переподключается к тому же чату при обрыве сети и при сбое сервера. [session] — один сеанс сокета; зовёт
    /// onConnected после "ready", а тот отвечает, первое ли это соединение разговора.
    private func withReconnects(_ onReady: @escaping () -> Void, session: (@escaping () -> Bool) async throws -> Void) async throws {
        var reconnectAttempt = 0
        // Не обнуляется при новом соединении: сервер, падающий сразу после "ready", иначе переподключал бы нас вечно.
        var serverFailures = 0
        var reportedReady = false
        while true {
            do {
                try await session {
                    reconnectAttempt = 0
                    let first = !reportedReady
                    if first {
                        reportedReady = true
                        onReady()
                    }
                    return first
                }
                return
            } catch VoiceError.network {
                // Обрыв сети — переподключаемся к тому же чату; сервер сам вытеснит зависшее старое соединение.
                guard reconnectAttempt < Self.reconnectDelays.count else { throw VoiceError.network }
                try await Task.sleep(for: .seconds(Self.reconnectDelays[reconnectAttempt]))
                reconnectAttempt += 1
            } catch VoiceError.kanatUnavailable(let message) {
                // Сбой сервера: сервер советует переподключиться раз-другой, не вышло — Канат недоступен.
                guard serverFailures < Self.serverFailureReconnects else { throw VoiceError.kanatUnavailable(message) }
                try await Task.sleep(for: .seconds(Self.reconnectDelays[serverFailures]))
                serverFailures += 1
            }
        }
    }

    /// Один разговор: его сеансы сокета и видео, не ушедшие в закрывавшееся соединение.
    private final class Conversation: @unchecked Sendable {
        let repository: VoiceRepositoryImpl
        let request: ConversationRequest
        /// Видео, взятые из videoRequests, когда соединение уже закрывалось: уходят первыми в следующее соединение.
        private var undeliveredVideos: [String] = []
        private let lock = NSLock()

        init(repository: VoiceRepositoryImpl, request: ConversationRequest) {
            self.repository = repository
            self.request = request
        }

        /// Один сеанс сокета, до штатного конца разговора. [microphone] — микрофон очков; nil — телефона.
        func run(microphone: DatMicrophone?, onConnected: @escaping () -> Bool) async throws {
            let throughGlasses = microphone != nil
            // Посмотреть Канат может только через очки, на которых идёт разговор, и только с разрешения в настройках.
            let vision = throughGlasses && repository.preferencesStorage.current().glassesVision
            let connection = try await repository.socket.open(chatId: request.chatId, vision: vision)
            defer { connection.close() }
            let firstConnection = onConnected()
            let connectedAtMs = uptimeMs()
            let timing = ConversationTiming(lastActivityAt: connectedAtMs)

            try await withThrowingTaskGroup(of: Bool.self) { group in
                // Микрофон → сервер. Кончиться сам может только поток с очков — связь с ними пропала.
                group.addTask {
                    try await self.streamMicrophone(microphone, connection: connection, firstConnection: firstConnection, connectedAtMs: connectedAtMs, timing: timing)
                    throw throughGlasses ? VoiceError.glassesDisconnected : VoiceError.microphoneUnavailable
                }
                // Разговор шёл через очки, а их сняли — голосовой режим выключаем, а не уводим в телефон.
                if throughGlasses {
                    group.addTask {
                        await self.repository.glasses.awaitTakenOff()
                        try Task.checkCancellation()
                        throw VoiceError.glassesTakenOff
                    }
                }
                // «Посмотри»: сервер ждёт ответа на каждый запрос, поэтому отвечаем и отказом.
                group.addTask {
                    while let id = try await connection.looks.next() {
                        connection.answerLook(id: id, photoId: await self.repository.look.take())
                    }
                    return false
                }
                // Живые кадры: пока Канату можно смотреть, с каждой фразой он видит то, что перед человеком сейчас.
                if vision, let microphone {
                    group.addTask {
                        for await jpeg in microphone.liveFrames(intervalMs: VoiceRepositoryImpl.liveFrameIntervalMs) {
                            // Зрение могут выключить посреди разговора — тогда кадры перестают уходить сразу.
                            guard self.repository.preferencesStorage.current().glassesVision else { break }
                            connection.sendFrame(jpeg)
                        }
                        // Кадры кончились — сервер забывает последний, чтобы не приложить его к фразе как «сейчас».
                        connection.sendCameraOff()
                        try await Task.sleep(for: .seconds(3600 * 24))
                        return false
                    }
                }
                // «Вот, смотри» — отдельный снимок по запросу, прикладывается к следующей фразе.
                group.addTask {
                    while let photoId = try await self.request.photoRequests.next() { connection.sendPhoto(photoId) }
                    try await Task.sleep(for: .seconds(3600 * 24))
                    return false
                }
                // Видео с очков — так же, к следующей фразе.
                group.addTask {
                    // Не ушло одно — закрывается и это соединение: остальные ждут следующего.
                    while let videoId = self.lock.withLock({ self.undeliveredVideos.first }) {
                        guard await connection.sendVideo(videoId) else { break }
                        self.lock.withLock { _ = self.undeliveredVideos.removeFirst() }
                    }
                    while let videoId = try await self.request.videoRequests.next() {
                        if !(await connection.sendVideo(videoId)) {
                            log.warning("Видео не ушло: соединение закрывается — отправим в следующее")
                            self.lock.withLock { self.undeliveredVideos.append(videoId) }
                        }
                    }
                    try await Task.sleep(for: .seconds(3600 * 24))
                    return false
                }
                group.addTask {
                    while let event = try await connection.events.next() {
                        if case .kanat(let activity) = event { timing.report(activity, self.request.onEvent) } else { self.request.onEvent(event) }
                    }
                    try await Task.sleep(for: .seconds(3600 * 24))
                    return false
                }
                // Ответ доиграл — Канат снова слушает. Конца звука плеер не сообщает: смотрим, когда он стихнет.
                group.addTask {
                    while true {
                        try await Task.sleep(for: .milliseconds(VoiceRepositoryImpl.kanatPollMs))
                        if timing.kanat == .speaking && uptimeMs() >= timing.speakingUntil {
                            timing.report(.listening, self.request.onEvent)
                        }
                    }
                }
                // Забытый разговор не держим вечно: выходим сами, когда минуту молчат и пользователь, и Канат.
                group.addTask {
                    while uptimeMs() - timing.lastActivityAt < VoiceRepositoryImpl.idleTimeoutMs {
                        try await Task.sleep(for: .seconds(1))
                        if self.request.videoPending() { timing.lastActivityAt = uptimeMs() }
                    }
                    return true
                }
                // Возвращается, когда сервер штатно закрыл разговор; ошибка отменит и микрофон.
                group.addTask {
                    try await self.playAnswers(connection: connection, timing: timing)
                    return true
                }
                // Первая завершившаяся задача: тишина или конец ответа — штатный выход, ошибка — пробрасываем.
                while let finished = try await group.next() {
                    if finished { break }
                }
                group.cancelAll()
            }
        }

        private func streamMicrophone(_ microphone: DatMicrophone?, connection: VoiceConnection, firstConnection: Bool, connectedAtMs: Int64, timing: ConversationTiming) async throws {
            let throughGlasses = microphone != nil
            // Сигнал начала — когда сервер уже слушает, и только в начале разговора, а не после обрыва сети.
            // Микрофон очков открыт раньше — пока звучит сигнал и его эхо, вместо звука с очков шлём тишину.
            let signalled = firstConnection ? await repository.signals.play(.conversationStarted) : false
            let quietUntilMs = signalled && throughGlasses ? uptimeMs() + signalEchoMs : 0
            var echo = EchoMeter(windowMs: VoiceRepositoryImpl.echoLogWindowMs)
            let chunks = microphone?.pcm(sinceMs: connectedAtMs, chunkBytes: PcmFormat.inputChunkBytes) ?? repository.recorder.record()
            for try await pcm in chunks {
                let now = uptimeMs()
                if throughGlasses, let line = echo.onChunk(nowMs: now, peak: peakAmplitude(pcm), kanatSpeaking: now < timing.speakingUntil) {
                    log.info(line)
                }
                // Сигнал камеры или «Канат получил» звучит в динамиках очков, а их микрофон пишется без эхоподавления.
                let signalEcho = throughGlasses && repository.tones.isSounding(atMs: now, echoMs: signalEchoMs)
                if request.muted() || now < quietUntilMs || signalEcho {
                    // Сокет не должен молчать дольше таймаута сервера — шлём тишину вместо речи.
                    try await connection.sendAudio(Data(count: pcm.count))
                } else {
                    if peakAmplitude(pcm) > VoiceRepositoryImpl.speechAmplitude { timing.lastActivityAt = uptimeMs() }
                    try await connection.sendAudio(pcm)
                }
            }
            log.warning("Звук микрофона оборвался посреди разговора")
        }

        private func playAnswers(connection: VoiceConnection, timing: ConversationTiming) async throws {
            // Сколько звучать оставалось, когда Канат встал на паузу: после неё доиграет остаток.
            var speakingLeftAtPause: Int64?
            try await repository.player.play(connection.audio) { event in
                let now = uptimeMs()
                if let activity = event.kanatActivity { timing.report(activity, self.request.onEvent) }
                switch event {
                case .chunk(let pcm):
                    timing.lastActivityAt = now
                    timing.speakingUntil = now + PcmFormat.outputDurationMs(pcm.count) + VoiceRepositoryImpl.echoTailMs
                case .subtitle(let text):
                    self.request.onSubtitle(text)
                case .heard(let text, let final):
                    self.request.onHeard(text, final)
                case .interrupt:
                    speakingLeftAtPause = nil
                    timing.speakingUntil = now + VoiceRepositoryImpl.echoTailMs
                    self.request.onSubtitle(nil)
                case .pause:
                    // Повторная пауза остатка не меняет: звук уже стоит.
                    if speakingLeftAtPause == nil {
                        speakingLeftAtPause = max(timing.speakingUntil - now, 0)
                        timing.speakingUntil = now + VoiceRepositoryImpl.echoTailMs
                    }
                case .resume:
                    if let left = speakingLeftAtPause {
                        speakingLeftAtPause = nil
                        timing.speakingUntil = now + left
                    }
                }
            }
        }
    }

    /// Очки на связи и надеты — только микрофон очков через поток камеры; если он не пошёл, голосовое не пишем вовсе,
    /// а говорим причину. Иначе — микрофон телефона.
    func recordNote(awaitStop: @escaping () async -> Void) async throws -> URL? {
        switch microphoneSource(glasses.currentDeviceInfo) {
        case .glasses: return try await recordNoteThroughGlasses(awaitStop)
        case .phone: return try await recordNoteOnPhone(awaitStop)
        }
    }

    private func recordNoteThroughGlasses(_ awaitStop: @escaping () async -> Void) async throws -> URL? {
        // Поток запускается секунды две — сигнал «говорите» звучит с первым звуком с очков.
        let outcome = await datNotes.record(awaitStop: awaitStop) { await self.signals.play(.recordingStarted) }
        switch outcome {
        // Поток с очков к этому времени уже выключен — сигнал конца в запись не попадёт.
        case .recorded(let file):
            await signals.play(.recordingStopped)
            return file
        case .unavailable(let reason):
            log.warning("Голосовое не записано: \(reason.rawValue)")
            let error = reason.voiceError
            if error.noPermission { audioPermissionPrompt.request() }
            throw error
        }
    }

    private func recordNoteOnPhone(_ awaitStop: @escaping () async -> Void) async throws -> URL? {
        try AudioSessionCoordinator.shared.activate(.voiceNote)
        defer { AudioSessionCoordinator.shared.deactivate(.voiceNote) }
        // Сигнал доигрывает до того, как откроется микрофон, а конца — после того, как он закрыт: в запись не попадают.
        await signals.play(.recordingStarted)
        let file = try await noteRecorder.record(awaitStop: awaitStop)
        await signals.play(.recordingStopped)
        return file
    }

    func sendNote(chatId: String, note: URL, photoIds: [String], videoId: String?, onSaved: @escaping () async -> Void) async throws {
        var questionSaved = false
        defer { try? FileManager.default.removeItem(at: note) }
        do {
            let reply = preferencesStorage.current().glassesVoiceReplies ? "voice" : nil
            try await mapChatErrors {
                for try await event in self.chats.askByVoice(chatId: chatId, recording: note, reply: reply, photoIds: photoIds, videoId: videoId) {
                    switch event {
                    case .questionSaved:
                        if !questionSaved {
                            questionSaved = true
                            await onSaved()
                        }
                    // Фразы ответа озвучиваем по порядку — play ждёт конца фразы, пауз между ними нет.
                    case .speech(_, _, let audio, _):
                        await self.speech.play(audio)
                    default:
                        break
                    }
                }
            }
            if !questionSaved { throw VoiceError.server("Сервер не подтвердил голосовое") }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Вопрос уже сохранён: повтор создал бы дубль, а ответ агент допишет в чат и без нас.
            if !questionSaved { throw error }
            log.warning("Озвучка ответа на голосовое оборвалась: \(error)")
        }
    }

    func signal(_ signal: VoiceSignal) async {
        await signals.play(signal)
    }

    private func mapChatErrors<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let error as ChatError {
            throw switch error {
            case .notAllowed: VoiceError.notAllowed
            case .microphoneUnavailable: VoiceError.microphoneUnavailable
            case .network: VoiceError.network
            case .notFound: VoiceError.chatNotFound
            case .server(let message): VoiceError.server(message)
            // Снимки из галереи шлёт только экран чата, голосовой режим сюда не попадает.
            case .photoUnavailable: VoiceError.server("\(error)")
            }
        }
    }
}

/// Время разговора, которое пишут микрофон, плеер и таймеры с разных задач.
private final class ConversationTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastActivityAt: Int64
    private var _speakingUntil: Int64 = 0
    private var _kanat: KanatActivity = .listening

    init(lastActivityAt: Int64) { _lastActivityAt = lastActivityAt }

    var lastActivityAt: Int64 {
        get { lock.withLock { _lastActivityAt } }
        set { lock.withLock { _lastActivityAt = newValue } }
    }

    /// До какого момента ещё звучит Канат — для замера эха и статуса «говорит».
    var speakingUntil: Int64 {
        get { lock.withLock { _speakingUntil } }
        set { lock.withLock { _speakingUntil = newValue } }
    }

    var kanat: KanatActivity { lock.withLock { _kanat } }

    /// Что делает Канат — по звуку ответа, а кадры "state" сервера лишь уточняют.
    func report(_ activity: KanatActivity, _ onEvent: (ConversationEvent) -> Void) {
        let changed: Bool = lock.withLock {
            defer { _kanat = activity }
            return _kanat != activity
        }
        if changed { onEvent(.kanat(activity)) }
    }
}

private let log = Log("VoiceRepository")
