import AVFoundation
import Combine
import Foundation

/// Голосовое в m4a (AAC): сервер принимает его как есть, и файл в разы меньше WAV.
final class AVVoiceNoteRecorder: VoiceNoteRecorder {
    private var recorder: AVAudioRecorder?
    private var startedAt: Int64 = 0

    func start() throws {
        precondition(recorder == nil, "Запись уже идёт")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            // Режим голоса: телефон сам подавляет шум и эхо — серверное шумоподавление в тишине распознавание ухудшает.
            try AudioSessionCoordinator.shared.activate(.voiceNote)
            let recorder = try AVAudioRecorder(url: output, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw ChatError.microphoneUnavailable }
            self.recorder = recorder
            startedAt = uptimeMs()
        } catch {
            try? FileManager.default.removeItem(at: output)
            AudioSessionCoordinator.shared.deactivate(.voiceNote)
            throw ChatError.microphoneUnavailable
        }
    }

    func stop() -> VoiceRecording? {
        guard let recorder else { return nil }
        self.recorder = nil
        let duration = uptimeMs() - startedAt
        recorder.stop()
        AudioSessionCoordinator.shared.deactivate(.voiceNote)
        let size = (try? recorder.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Звука записать не успели — отправлять нечего.
        guard size > 0 else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        return VoiceRecording(file: recorder.url, durationMs: duration)
    }

    func cancel() {
        if let recording = stop() { try? FileManager.default.removeItem(at: recording.file) }
    }

    var level: Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        // −50 dB и тише — тишина, 0 dB — во всю высоту.
        return max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
    }
}

/// Проигрывает голосовые: черновик — из файла, вопрос из истории — скачанной записью,
/// ответ без записи — озвучкой, которую сервер присылает целиком.
final class AVVoicePlayer: NSObject, VoicePlayer, AVAudioPlayerDelegate {
    let playing = CurrentValueSubject<VoiceClip?, Never>(nil)

    private let chats: ChatRepository
    private var player: AVAudioPlayer?

    init(chats: ChatRepository) {
        self.chats = chats
    }

    @MainActor
    func toggle(_ clip: VoiceClip) async {
        let wasPlaying = playing.value
        stop()
        if wasPlaying == clip { return }
        // Сразу, а не после подготовки: озвучка грузится секунды, и всё это время кнопка должна её останавливать.
        playing.send(clip)
        let made: AVAudioPlayer?
        do {
            made = try await audioPlayer(clip)
        } catch {
            log.warning("Не удалось получить звук \(clip): \(error)")
            made = nil
        }
        // Пока звук готовился, его могли остановить или включить другой.
        guard playing.value == clip else { return }
        guard let made else {
            playing.send(nil)
            return
        }
        try? AudioSessionCoordinator.shared.activate(.playback)
        made.delegate = self
        player = made
        if !made.play() { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        if playing.value != nil {
            playing.send(nil)
            AudioSessionCoordinator.shared.deactivate(.playback)
        }
    }

    private func audioPlayer(_ clip: VoiceClip) async throws -> AVAudioPlayer {
        switch clip {
        case .draft(let file): return try AVAudioPlayer(contentsOf: file)
        case .message(let id): return try AVAudioPlayer(contentsOf: try await chats.messageAudio(messageId: id))
        case .speech(_, let text): return try AVAudioPlayer(data: try await chats.speech(text: text))
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            if self?.player === player { self?.stop() }
        }
    }
}

private let log = Log("VoiceMedia")
