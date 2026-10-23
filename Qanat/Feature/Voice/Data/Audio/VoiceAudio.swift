import AVFoundation
import Foundation

/// Формат голосового режима сервера: 16-бит PCM little-endian, моно.
enum PcmFormat {
    /// Микрофон → сервер. Очки через поток камеры отдают ровно 16 кГц, телефон передискретизируем сами.
    static let inputSampleRate = 16_000
    /// Сервер → динамик.
    static let outputSampleRate = 24_000
    /// Сервер принимает куски по 20–100 мс.
    static let inputChunkBytes = inputSampleRate * 2 * 40 / 1000

    /// Сколько звучат [bytes] ответа сервера.
    static func outputDurationMs(_ bytes: Int) -> Int64 { Int64(bytes) * 1000 / Int64(outputSampleRate * 2) }
}

/// Режет поток PCM на куски ровно по [chunkBytes] без потерь и разрывов: остаток ждёт следующих данных.
struct PcmRechunker {
    let chunkBytes: Int
    private var pending = Data()

    init(chunkBytes: Int) {
        precondition(chunkBytes > 0 && chunkBytes % 2 == 0, "Кусок должен быть из целых сэмплов: \(chunkBytes)")
        self.chunkBytes = chunkBytes
    }

    /// Принимает [pcm] и возвращает куски, что набрались целиком.
    mutating func push(_ pcm: Data) -> [Data] {
        pending.append(pcm)
        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(Data(pending.prefix(chunkBytes)))
            pending.removeFirst(chunkBytes)
        }
        return chunks
    }

    /// Недобранный хвост — когда данных больше не будет; nil — его нет.
    mutating func drain() -> Data? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : pending
    }
}

/// Замер эха: громкость микрофона очков, пока Канат говорит в их динамики и пока молчит. Системного эхоподавления
/// у потока камеры нет. Раз в [windowMs] отдаёт строку для лога и начинает окно заново.
struct EchoMeter {
    let windowMs: Int64
    private var windowStartMs: Int64 = -1
    private var speakingPeak = 0
    private var silentPeak = 0

    init(windowMs: Int64) { self.windowMs = windowMs }

    mutating func onChunk(nowMs: Int64, peak: Int, kanatSpeaking: Bool) -> String? {
        if windowStartMs < 0 { windowStartMs = nowMs }
        if kanatSpeaking { speakingPeak = max(speakingPeak, peak) } else { silentPeak = max(silentPeak, peak) }
        guard nowMs - windowStartMs >= windowMs else { return nil }
        let line = "Пик микрофона очков за \(nowMs - windowStartMs) мс: пока говорит Канат \(speakingPeak), пока молчит \(silentPeak)"
        windowStartMs = nowMs
        speakingPeak = 0
        silentPeak = 0
        return line
    }
}

/// Почему голосовое закончилось само — без двойного нажатия.
enum NoteEnd: String {
    case maxDuration = "лимит длины"
    case pauseAfterSpeech = "пауза после речи"
    case noSpeech = "речи не было"
}

/// Конец голосового без кнопки: нажатие на очках может и не дойти, поэтому запись заканчивается и сама — по паузе
/// после речи или по лимиту длины. Время — uptimeMs. Пока к голосовому снимают видео ([onVideo]), пауза не идёт.
struct NoteEndDetector {
    // Человек может задуматься на несколько секунд — страховка, а не нормальный конец фразы (его даёт двойное нажатие).
    static let pauseAfterSpeechMs: Int64 = 10_000
    static let noSpeechTimeoutMs: Int64 = 10_000
    // Сервер принимает до 11 МБ — 5 минут нужны только как страховка от зависшей записи.
    static let maxDurationMs: Int64 = 5 * 60_000

    let startedAtMs: Int64
    private(set) var spoke = false
    /// Самый громкий уровень — для отладки порога.
    private(set) var loudest = 0
    private var lastSpeechAtMs: Int64 = 0
    private var lastVideoAtMs = Int64.min / 2

    init(startedAtMs: Int64) { self.startedAtMs = startedAtMs }

    /// [amplitude] — пик с прошлого вызова, 0..32767. Возвращает причину конца или nil — пишем дальше.
    mutating func onLevel(timeMs: Int64, amplitude: Int) -> NoteEnd? {
        loudest = max(loudest, amplitude)
        if amplitude > speechPeakAmplitude {
            spoke = true
            lastSpeechAtMs = timeMs
        }
        return check(timeMs: timeMs)
    }

    /// К голосовому в [timeMs] снимается видео: паузу и ожидание речи отсчитываем с конца съёмки.
    mutating func onVideo(timeMs: Int64) { lastVideoAtMs = timeMs }

    /// Без нового уровня: звук не приходит, а время идёт.
    func check(timeMs: Int64) -> NoteEnd? {
        if timeMs - startedAtMs > Self.maxDurationMs { return .maxDuration }
        if spoke && timeMs - max(lastSpeechAtMs, lastVideoAtMs) > Self.pauseAfterSpeechMs { return .pauseAfterSpeech }
        if !spoke && timeMs - max(startedAtMs, lastVideoAtMs) > Self.noSpeechTimeoutMs { return .noSpeech }
        return nil
    }
}

/// Пишет микрофон телефона блоками PCM 16 кГц моно — когда разговор идёт не через очки. Эхоподавление
/// (voice processing) включено: иначе ответ Каната из динамика его же перебьёт.
final class PcmRecorder {
    /// Запись идёт непрерывно, пока поток читают, — сервер ждёт и тишину. Отмена её останавливает.
    func record() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            do {
                try input.setVoiceProcessingEnabled(true)
                let inputFormat = input.outputFormat(forBus: 0)
                let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PcmFormat.inputSampleRate), channels: 1, interleaved: true)!
                guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: target) else {
                    throw VoiceError.microphoneUnavailable
                }
                var rechunker = PcmRechunker(chunkBytes: PcmFormat.inputChunkBytes)
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                    guard let pcm = convert(buffer, with: converter, to: target) else { return }
                    for chunk in rechunker.push(pcm) { continuation.yield(chunk) }
                }
                engine.prepare()
                try engine.start()
            } catch {
                continuation.finish(throwing: VoiceError.microphoneUnavailable)
                return
            }
            continuation.onTermination = { _ in
                input.removeTap(onBus: 0)
                engine.stop()
            }
        }
    }
}

/// [buffer] микрофона → PCM s16le в [format] через [converter].
func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> Data? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if consumed {
            status.pointee = .noDataNow
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
    guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
    return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
}

/// Проигрывает PCM ответа Каната (24 кГц моно). Звук идёт туда, куда ведёт аудиосессия: в разговоре с телефона —
/// громкая связь с эхоподавлением, с очками — их динамики (Bluetooth).
final class PcmPlayer {
    /// Играет [events] по мере прихода. [pause] останавливает звук, ничего не теряя; [interrupt] выбрасывает всё
    /// недоигранное и снимает паузу. [onEvent] получает каждое событие: кусок звука и субтитр — когда до них дошла
    /// очередь, остальные — сразу. Возвращается, когда поток закончился и всё доиграно (на паузе — сразу).
    /// Поток, закрытый с ошибкой, бросает её, доиграв пришедшее до неё. На главном потоке: там же и состояние очереди.
    @MainActor
    func play(_ events: AsyncQueue<Playback>, onEvent: @escaping (Playback) -> Void) async throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PcmFormat.outputSampleRate), channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
        defer {
            node.stop()
            engine.stop()
        }

        // Счётчик поколений: после interrupt доигрывание старых буферов уже ничего не значит.
        let state = PlayerState()
        var paused = false
        var failure: Error?
        while true {
            let event: Playback?
            do {
                event = try await events.next()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
                event = nil
            }
            guard let event else { break }
            switch event {
            case .chunk(let pcm):
                guard let buffer = floatBuffer(pcm, format: format) else { continue }
                let generation = state.generation
                state.scheduled += 1
                // Кусок «зазвучал», когда до него дошла очередь.
                let startsNow = state.scheduled == 1
                if startsNow { onEvent(event) } else { state.pending.append(.chunkStarted(event)) }
                node.scheduleBuffer(buffer) {
                    DispatchQueue.main.async { state.finished(generation: generation, onEvent: onEvent) }
                }
            case .subtitle:
                // Субтитр — когда звук до него дошёл.
                if state.scheduled == 0 { onEvent(event) } else { state.pending.append(.subtitle(event)) }
            case .pause:
                if !paused {
                    paused = true
                    node.pause()
                }
                onEvent(event)
            case .resume:
                if paused {
                    paused = false
                    node.play()
                }
                onEvent(event)
            case .interrupt:
                paused = false
                state.reset()
                node.stop()
                node.play()
                onEvent(event)
            case .heard:
                onEvent(event)
            }
        }
        if let failure { throw failure }
        if paused { return }
        // scheduleBuffer возвращается сразу — ждём, пока всё запланированное прозвучит.
        while state.scheduled > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func floatBuffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        return buffer
    }
}

/// Очередь плеера: сколько буферов ещё звучит и какие события ждут своего места в звуке. Только на главном потоке.
private final class PlayerState {
    enum Pending {
        case chunkStarted(Playback)
        case subtitle(Playback)
    }

    var generation = 0
    var scheduled = 0
    var pending: [Pending] = []

    func reset() {
        generation += 1
        scheduled = 0
        pending.removeAll()
    }

    /// Доиграл буфер поколения [generation]: следующий кусок зазвучал, субтитры перед ним — показываются.
    func finished(generation: Int, onEvent: (Playback) -> Void) {
        guard generation == self.generation else { return }
        scheduled = max(0, scheduled - 1)
        while let first = pending.first {
            switch first {
            case .subtitle(let event):
                pending.removeFirst()
                onEvent(event)
            case .chunkStarted(let event):
                pending.removeFirst()
                onEvent(event)
                return
            }
        }
    }
}

/// Голосовое в m4a (AAC) с микрофона телефона — тот же формат, что у голосовых из чата: 16 кГц моно 32 кбит/с.
/// Нажатие кнопки очков может и не дойти, поэтому запись заканчивается и сама — [NoteEndDetector].
final class NoteRecorder {
    /// Возвращает файл записи или nil, если речи не было.
    func record(awaitStop: @escaping () async -> Void) async throws -> URL? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).m4a")
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: output, settings: aacNoteSettings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw VoiceError.microphoneUnavailable }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw VoiceError.microphoneUnavailable
        }
        var keep = false
        defer {
            if recorder.isRecording { recorder.stop() }
            if !keep { try? FileManager.default.removeItem(at: output) }
        }
        let stoppedByButton = StopFlag()
        let stop = Task {
            await awaitStop()
            if !Task.isCancelled { stoppedByButton.set() }
        }
        defer { stop.cancel() }
        var detector = NoteEndDetector(startedAtMs: uptimeMs())
        while !stoppedByButton.isSet {
            try await Task.sleep(for: .milliseconds(100))
            recorder.updateMeters()
            // Пик с прошлого вызова в дБ → 0..32767.
            let amplitude = Int(32767 * pow(10, Double(recorder.peakPower(forChannel: 0)) / 20))
            if let ended = detector.onLevel(timeMs: uptimeMs(), amplitude: amplitude) {
                log.debug("Запись закончена: \(ended.rawValue), громкость до \(detector.loudest)")
                break
            }
        }
        recorder.stop()
        keep = detector.spoke || stoppedByButton.isSet
        return keep ? output : nil
    }
}

/// Флаг между задачами.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Настройки голосовых: m4a (AAC-LC) 16 кГц моно 32 кбит/с — сервер принимает его как есть (audio/mp4).
let aacNoteSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 16_000,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 32_000,
]

/// Кодирует PCM s16le моно 16 кГц в m4a — в тот же формат, что пишет [NoteRecorder].
final class AacNoteWriter {
    private let file: AVAudioFile
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private(set) var hasAudio = false

    init(output: URL) throws {
        file = try AVAudioFile(forWriting: output, settings: aacNoteSettings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func write(_ pcm: Data) throws {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        try file.write(from: buffer)
        hasAudio = true
    }
}

/// Звуковые сигналы голосового режима — тоны подобраны так, чтобы не путаться на слух друг с другом.
final class SignalPlayer {
    private let tones: TonePlayer
    private let preferencesStorage: PreferencesStorage

    init(tones: TonePlayer, preferencesStorage: PreferencesStorage) {
        self.tones = tones
        self.preferencesStorage = preferencesStorage
    }

    /// Возвращается, когда сигнал доиграл. Сигналы начала и конца выключаются в настройках; остальные звучат всегда.
    /// false — сигнал выключен и не звучал: глушить его эхо в микрофоне не нужно.
    @discardableResult
    func play(_ signal: VoiceSignal) async -> Bool {
        if signal.isStartOrEnd && !preferencesStorage.current().startEndSounds { return false }
        log.debug("Воспроизведение сигнала \(signal)")
        await tones.play(signal.tones)
        return true
    }
}

extension VoiceSignal {
    /// Сигналы начала и конца — записи, разговора и связи с очками: их выключает настройка «Звуки начала и конца».
    var isStartOrEnd: Bool {
        switch self {
        case .recordingStarted, .recordingStopped, .conversationStarted, .conversationEnded, .glassesLinked: true
        case .noteSent, .newChat, .failed, .attached: false
        }
    }

    /// Голосовое — две ноты квинтой вверх и вниз, разговор — мягкое арпеджио до-ми-соль шестой октавы вверх и вниз.
    /// Связь с очками — мягкая кварта соль-до вверх. «Канат получил снимок или видео» — два коротких высоких щелчка.
    var tones: [Tone] {
        let g5 = 784.0, c6 = 1046.5, e6 = 1318.5, g6 = 1568.0, a6 = 1760.0
        switch self {
        case .recordingStarted: return [Tone(frequencyHz: 880, durationMs: 60), Tone(frequencyHz: 1320, durationMs: 60)]
        case .recordingStopped: return [Tone(frequencyHz: 1320, durationMs: 75), Tone(frequencyHz: 880, durationMs: 75)]
        case .conversationStarted: return [Tone(frequencyHz: c6, durationMs: 100), Tone(frequencyHz: e6, durationMs: 100), Tone(frequencyHz: g6, durationMs: 100)]
        case .conversationEnded: return [Tone(frequencyHz: g6, durationMs: 100), Tone(frequencyHz: e6, durationMs: 100), Tone(frequencyHz: c6, durationMs: 100)]
        case .noteSent: return [Tone(frequencyHz: 587, durationMs: 100), Tone(frequencyHz: 880, durationMs: 100)]
        case .newChat: return [Tone(frequencyHz: 440, durationMs: 100), Tone(frequencyHz: 660, durationMs: 100), Tone(frequencyHz: 880, durationMs: 100)]
        case .failed: return failureTones
        case .glassesLinked: return [Tone(frequencyHz: g5, durationMs: 100), Tone(frequencyHz: c6, durationMs: 100)]
        case .attached: return [Tone(frequencyHz: a6, durationMs: 60), Tone(frequencyHz: 0, durationMs: 50), Tone(frequencyHz: a6, durationMs: 60)]
        }
    }
}

/// Проигрывает фразы голосового ответа агента (mp3) одну за другой — вызывающий ждёт конца фразы.
final class SpeechPlayer: NSObject, AVAudioPlayerDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var player: AVAudioPlayer?

    @MainActor
    func play(_ mp3: Data) async {
        do {
            try AudioSessionCoordinator.shared.activate(.playback)
        } catch {
            log.warning("Аудиосессия для фразы ответа недоступна: \(error)")
        }
        defer { AudioSessionCoordinator.shared.deactivate(.playback) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                do {
                    let player = try AVAudioPlayer(data: mp3)
                    player.delegate = self
                    self.player = player
                    self.continuation = continuation
                    if !player.play() { finish() }
                } catch {
                    // Битую фразу пропускаем: остальной ответ важнее.
                    log.warning("Не удалось воспроизвести фразу ответа: \(error)")
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
    }

    @MainActor
    private func finish() {
        player?.stop()
        player = nil
        continuation?.resume()
        continuation = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }
}

private let log = Log("VoiceAudio")
