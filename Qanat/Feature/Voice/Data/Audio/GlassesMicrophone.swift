import Foundation

/// Почему микрофон очков (поток камеры Meta SDK) недоступен. Записать на другой микрофон молча нельзя — говорим причину.
enum DatMicFailure: String {
    case notConnected = "очков нет на связи"
    case noPermission = "камера или микрофон очков не разрешены в Meta AI"
    case cameraBusy = "камера очков занята съёмкой"
    case streamError = "поток камеры не пошёл или оборвался до речи"
    case noAudio = "звук с очков не пришёл вовремя"
    case encoder = "кодек AAC недоступен"

    init(_ error: GlassesAudioError) {
        self = switch error {
        case .notConnected: .notConnected
        case .noPermission: .noPermission
        case .busy: .cameraBusy
        case .streamError: .streamError
        }
    }

    /// Без разрешения в Meta AI — просим его, камера занята видео — так и говорим, остальное — сбой.
    var voiceError: VoiceError {
        switch self {
        case .noPermission: .glassesMicrophoneUnavailable(.noPermission)
        case .cameraBusy: .glassesMicrophoneUnavailable(.cameraBusy)
        default: .glassesMicrophoneUnavailable(.failed)
        }
    }
}

/// От начала записи до первого звука с очков; дольше — микрофон очков недоступен. Обычно звук приходит за ~2,3 с.
let firstGlassesAudioTimeoutMs: Int64 = 4_000

/// Сколько после конца сигнала его звук ещё может идти с очков: задержка динамика и потока камеры.
let signalEchoMs: Int64 = 500

/// Значение signalEndedAtMs, когда сигнала «говорите» не было: эха нет, пишется всё.
let noSignal = Int64.min / 2

/// Кадр с микрофона очков пришёл, пока звучал сигнал «говорите», или вскоре после: их микрофон в потоке камеры
/// пишется без эхоподавления. Такие кадры не идут ни в запись, ни в замер речи.
func isSignalEcho(_ frame: GlassesAudioFrame, signalEndedAtMs: Int64) -> Bool {
    frame.arrivedAtMs <= signalEndedAtMs + signalEchoMs
}

extension GlassesAudioCapture {
    /// Запуск потока со звуком для [use] не дольше [timeoutMs]; nil — не успел. Поток, пошедший уже после таймаута,
    /// не теряем: его выключаем сразу.
    func startAudio(_ use: GlassesAudioUse, timeoutMs: Int64) async -> GlassesAudioStart? {
        let box = ResultBox<GlassesAudioStart>()
        let task = Task { () -> GlassesAudioStart in
            let start = await startAudio(use)
            if box.set(start) == false, case .started(let audio) = start { await audio.stop() }
            return start
        }
        let timer = Task {
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            _ = box.set(nil)
        }
        defer { timer.cancel() }
        _ = await withTaskCancellationHandler {
            await box.wait()
        } onCancel: {
            task.cancel()
        }
        return box.value
    }
}

/// Первый пришедший результат из нескольких задач; set после него — false.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private(set) var value: T?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Результат уже есть (в том числе nil).
    var isSet: Bool { lock.withLock { done } }

    @discardableResult
    func set(_ value: T?) -> Bool {
        let resumed: [CheckedContinuation<Void, Never>]? = lock.withLock {
            guard !done else { return nil }
            done = true
            self.value = value
            defer { waiters.removeAll() }
            return waiters
        }
        guard let resumed else { return false }
        resumed.forEach { $0.resume() }
        return true
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if done { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Чем кончилась попытка записать голосовое через поток камеры очков.
enum DatNoteOutcome {
    /// Записали: file — m4a, его удалит отправка; nil — речи не было.
    case recorded(URL?)
    /// Речи ещё не было, а звук с очков недоступен — голосовое не записано.
    case unavailable(DatMicFailure)
}

/// Голосовое с микрофона очков через поток камеры Meta SDK, в тот же m4a, что и [NoteRecorder].
/// Поток запускается секунды две, поэтому [onListening] (сигнал «говорите») зовётся только с первым звуком, а пишем
/// то, что пришло после сигнала и его эха. Сказанное не теряется и при обрыве потока посреди речи.
final class DatNoteRecorder {
    private let capture: GlassesAudioCapture
    private let camera: GlassesCamera
    private let tones: TonePlayer

    /// Сколько после двойного нажатия ещё ждём звук, уже сказанный, но не дошедший с очков.
    private static let stopTailMs: Int64 = 300

    init(capture: GlassesAudioCapture, camera: GlassesCamera, tones: TonePlayer) {
        self.capture = capture
        self.camera = camera
        self.tones = tones
    }

    func record(awaitStop: @escaping () async -> Void, onListening: @escaping () async -> Bool) async -> DatNoteOutcome {
        let stopped = StopFlag()
        let stopTask = Task {
            await awaitStop()
            if !Task.isCancelled { stopped.set() }
        }
        defer { stopTask.cancel() }
        let deadline = uptimeMs() + firstGlassesAudioTimeoutMs
        let audio: GlassesAudio
        switch await capture.startAudio(.note, timeoutMs: firstGlassesAudioTimeoutMs) {
        case nil: return .unavailable(.noAudio)
        case .failed(let error): return .unavailable(DatMicFailure(error))
        case .started(let started): audio = started
        }
        defer { Task { await audio.stop() } }

        // Первый звук, остановка кнопкой или таймаут.
        var first: GlassesAudioFrame?
        while first == nil {
            if stopped.isSet { return .recorded(nil) }
            if uptimeMs() > deadline { return .unavailable(audio.error.map(DatMicFailure.init) ?? .noAudio) }
            if let frame = audio.frames.tryNext() {
                first = frame
            } else if audio.frames.isFinished {
                return .unavailable(audio.error.map(DatMicFailure.init) ?? .noAudio)
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        log.info("Голосовое через очки: первый звук через \(first!.arrivedAtMs - audio.startedAtMs) мс")
        // Сигнал доигрывает до записи: кадры, пришедшие за это время, ждут в очереди и отсеются как эхо.
        let signalled = await onListening()
        let signalEndedAtMs = signalled ? uptimeMs() : noSignal
        return await write(first: first!, audio: audio, stopped: stopped, signalEndedAtMs: signalEndedAtMs)
    }

    private func write(first: GlassesAudioFrame, audio: GlassesAudio, stopped: StopFlag, signalEndedAtMs: Int64) async -> DatNoteOutcome {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).m4a")
        let writer: AacNoteWriter
        do {
            writer = try AacNoteWriter(output: output)
        } catch {
            log.warning("Кодек AAC не запустился: \(error)")
            return .unavailable(.encoder)
        }
        var detector = NoteEndDetector(startedAtMs: uptimeMs())
        var keep = false
        defer {
            if !keep { try? FileManager.default.removeItem(at: output) }
            // Порог речи подобран под микрофоны гарнитур — уровень микрофона очков нужен и в release.
            log.info("Голосовое через очки: громкость до \(detector.loudest), речь была: \(detector.spoke)")
        }
        do {
            var next: GlassesAudioFrame? = first
            loop: while true {
                // Видео к голосовому снимается: голосовое не кончается само, пока человек снимает молча.
                if camera.isRecordingVideo { detector.onVideo(timeMs: uptimeMs()) }
                if let frame = next {
                    next = nil
                    // Сигналы камеры очков звучат в их динамиках посреди голосового — их эхо в запись не пускаем.
                    if !isSignalEcho(frame, signalEndedAtMs: signalEndedAtMs) && !tones.isSounding(atMs: frame.arrivedAtMs, echoMs: signalEchoMs) {
                        try writer.write(frame.pcm)
                        if let ended = detector.onLevel(timeMs: uptimeMs(), amplitude: peakAmplitude(frame.pcm)) {
                            log.debug("Запись закончена: \(ended.rawValue), громкость до \(detector.loudest)")
                            break loop
                        }
                    }
                } else if let ended = detector.check(timeMs: uptimeMs()) {
                    log.debug("Запись закончена: \(ended.rawValue), громкость до \(detector.loudest)")
                    break loop
                }
                if stopped.isSet {
                    log.debug("Запись остановлена кнопкой, громкость до \(detector.loudest)")
                    // Последние слова перед нажатием ещё в пути с очков — дописываем и их.
                    let tailUntil = uptimeMs() + Self.stopTailMs
                    while uptimeMs() < tailUntil {
                        if let frame = audio.frames.tryNext() { try writer.write(frame.pcm) } else { try? await Task.sleep(for: .milliseconds(20)) }
                    }
                    break loop
                }
                if let frame = audio.frames.tryNext() {
                    next = frame
                } else if audio.frames.isFinished {
                    log.warning("Звук с очков оборвался посреди голосового: \(String(describing: audio.error)), речь была: \(detector.spoke)")
                    // Речи ещё не было — терять нечего: голосовое не записано, причину скажем пользователю.
                    if !detector.spoke { return .unavailable(audio.error.map(DatMicFailure.init) ?? .streamError) }
                    break loop
                } else {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if Task.isCancelled { return .recorded(nil) }
            }
            // stop() закрывает поток, но кадры из очереди он отдаёт до конца — пишем и их.
            await audio.stop()
            while let frame = audio.frames.tryNext() { try writer.write(frame.pcm) }
            keep = writer.hasAudio && (detector.spoke || stopped.isSet)
            return .recorded(keep ? output : nil)
        } catch {
            log.warning("Кодек сломался посреди голосового, речь была: \(detector.spoke): \(error)")
            // Сказанное не теряем: в файле остаётся то, что кодек успел записать до сбоя.
            keep = writer.hasAudio && (detector.spoke || stopped.isSet)
            return keep ? .recorded(output) : .unavailable(.encoder)
        }
    }
}

/// Микрофон очков на весь разговор с Канатом: поток камеры со звуком включается один раз, когда разговор начинается,
/// и держится до его конца — и через переподключения сокета.
final class GlassesConversationMicrophone {
    private let capture: GlassesAudioCapture

    init(capture: GlassesAudioCapture) {
        self.capture = capture
    }

    /// Включает поток, дожидается первого звука и отдаёт микрофон [block]; по выходе из [block] выключает камеру.
    /// Бросает glassesMicrophoneUnavailable — звук с очков не пошёл: другой микрофон молча не берём.
    func use<T>(_ block: (DatMicrophone) async throws -> T) async throws -> T {
        let startedAtMs = uptimeMs()
        let audio: GlassesAudio
        switch await capture.startAudio(.conversation, timeoutMs: firstGlassesAudioTimeoutMs) {
        case nil: throw unavailable(.noAudio)
        case .failed(let error): throw unavailable(DatMicFailure(error))
        case .started(let started): audio = started
        }
        do {
            var first: GlassesAudioFrame?
            while first == nil {
                if let frame = audio.frames.tryNext() {
                    first = frame
                } else if audio.frames.isFinished || uptimeMs() - startedAtMs > firstGlassesAudioTimeoutMs {
                    throw unavailable(audio.error.map(DatMicFailure.init) ?? .noAudio)
                } else {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            log.info("Разговор через микрофон очков: первый звук через \(first!.arrivedAtMs - audio.startedAtMs) мс")
            let result = try await block(DatMicrophone(audio: audio))
            await audio.stop()
            return result
        } catch {
            await audio.stop()
            throw error
        }
    }

    private func unavailable(_ reason: DatMicFailure) -> VoiceError {
        log.warning("Микрофон очков для разговора недоступен: \(reason.rawValue)")
        return reason.voiceError
    }
}

/// Идущий звук микрофона очков — и кадры с той же камеры.
final class DatMicrophone {
    private let audio: GlassesAudio

    init(audio: GlassesAudio) {
        self.audio = audio
    }

    /// PCM s16le 16 кГц моно для сокета кусками по [chunkBytes], без разрывов. Только то, что пришло не раньше
    /// [sinceMs]: накопленное, пока сокет переподключался, уже устарело. Кончается, когда поток с очков оборвался.
    func pcm(sinceMs: Int64, chunkBytes: Int) -> AsyncThrowingStream<Data, Error> {
        let frames = audio.frames
        return AsyncThrowingStream { continuation in
            let task = Task {
                var rechunker = PcmRechunker(chunkBytes: chunkBytes)
                do {
                    while let frame = try await frames.next() {
                        guard frame.arrivedAtMs >= sinceMs else { continue }
                        for chunk in rechunker.push(frame.pcm) { continuation.yield(chunk) }
                    }
                    if let tail = rechunker.drain() { continuation.yield(tail) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// JPEG-кадры с камеры, через которую идёт звук, — не чаще раза в [intervalMs].
    func liveFrames(intervalMs: Int64) -> AsyncStream<Data> { audio.liveFrames(intervalMs: intervalMs) }
}

private let log = Log("DatMic")
