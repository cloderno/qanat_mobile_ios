import AVFoundation
import Foundation

/// Нота сигнала: синус [frequencyHz] длиной [durationMs]; частота 0 — пауза.
struct Tone: Equatable {
    let frequencyHz: Double
    let durationMs: Int
}

/// Сбой звучит одинаково, что бы ни сломалось, — голосовая команда или съёмка с очков: низкий двойной сигнал.
let failureTones = [Tone(frequencyHz: 440, durationMs: 150), Tone(frequencyHz: 0, durationMs: 80), Tone(frequencyHz: 440, durationMs: 150)]

/// PCM 16 бит моно для коротких сигналов. Каждая нота — синус с плавным нарастанием и спадом ([rampMs]), поэтому
/// ни на краях, ни на стыке нот нет щелчков. Громкость — [levelDbfs]: сигнал заметен, но не громче речи Каната.
enum ToneSynth {
    static let sampleRate = 16_000
    static let levelDbfs = -18.0
    static let rampMs = 8

    /// Пик синуса в отсчётах: 10^(−18/20) от полной шкалы, ≈ 4125.
    static let peak = Int((pow(10, levelDbfs / 20) * Double(Int16.max)).rounded())

    static func samples(_ durationMs: Int) -> Int { durationMs * sampleRate / 1000 }

    static func render(_ tones: [Tone]) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: tones.reduce(0) { $0 + samples($1.durationMs) })
        var offset = 0
        for tone in tones {
            let count = samples(tone.durationMs)
            if tone.frequencyHz > 0 {
                let ramp = min(samples(rampMs), count / 2)
                for i in 0..<count {
                    // От первого отсчёта ноты до последнего огибающая идёт от нуля и к нулю.
                    let envelope: Double = if i < ramp { fade(i, ramp) } else if i >= count - ramp { fade(count - 1 - i, ramp) } else { 1 }
                    let value = sin(2 * .pi * tone.frequencyHz * Double(i) / Double(sampleRate)) * Double(peak) * envelope
                    pcm[offset + i] = Int16(value.rounded())
                }
            }
            offset += count
        }
        return pcm
    }

    /// Половина косинуса: 0 при i = 0 и 1 при i = ramp — мягче линейного нарастания.
    private static func fade(_ i: Int, _ ramp: Int) -> Double { (1 - cos(.pi * Double(i) / Double(ramp))) / 2 }
}

/// Короткие звуковые сигналы. Помнит, когда звучал последний сигнал ([isSounding]): микрофон очков пишется без
/// эхоподавления, и сигнал камеры, сыгранный в их динамиках посреди голосового или разговора, иначе ушёл бы туда как речь.
final class TonePlayer {
    private let lock = NSLock()
    private var soundingFromMs = Int64.min / 2
    private var soundingUntilMs = Int64.min / 2
    private var playing = 0

    private static let maxStartDelayMs: Int64 = 500
    private static let tailMs: Int64 = 50
    /// Сигнал, начатый позже прежнего на это время и больше, открывает новое окно: эхо прежнего уже дошло.
    private static let maxEchoMs: Int64 = 1_000

    /// Мог ли в момент [atMs] (uptimeMs) звучать сигнал — с запасом [echoMs] на путь звука обратно в микрофон.
    func isSounding(atMs: Int64, echoMs: Int64) -> Bool {
        lock.withLock { atMs >= soundingFromMs && atMs <= soundingUntilMs + echoMs }
    }

    /// Играет [tones] подряд и возвращается, когда сигнал доиграл: после него можно открывать микрофон.
    func play(_ tones: [Tone]) async {
        let pcm = ToneSynth.render(tones)
        guard !pcm.isEmpty else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ToneSynth.sampleRate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        let channel = buffer.floatChannelData![0]
        for (i, sample) in pcm.enumerated() { channel[i] = Float(sample) / Float(Int16.max) }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try AudioSessionCoordinator.shared.activate(.playback)
            defer { AudioSessionCoordinator.shared.deactivate(.playback) }
            try engine.start()
            let durationMs = Int64(pcm.count) * 1000 / Int64(ToneSynth.sampleRate)
            markSounding(startMs: uptimeMs(), durationMs: durationMs)
            var endedMs: Int64?
            defer { markPlayed(endedMs: endedMs) }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in continuation.resume() }
                node.play()
            }
            // Отданное плеером ещё идёт по тракту (Bluetooth и т. п.) — даём хвосту доиграть.
            try? await Task.sleep(for: .milliseconds(Self.tailMs))
            endedMs = uptimeMs()
            node.stop()
            engine.stop()
        } catch {
            log.warning("Ошибка воспроизведения сигнала \(tones): \(error)")
        }
    }

    private func markSounding(startMs: Int64, durationMs: Int64) {
        lock.withLock {
            playing += 1
            if startMs > soundingUntilMs + Self.maxEchoMs { soundingFromMs = startMs }
            soundingUntilMs = max(soundingUntilMs, startMs + durationMs + Self.maxStartDelayMs + Self.tailMs)
        }
    }

    /// Сигнал доиграл к [endedMs] — окно кончается тогда же; nil — сигнал оборвался: окно остаётся с запасом.
    private func markPlayed(endedMs: Int64?) {
        lock.withLock {
            playing -= 1
            if playing == 0, let endedMs { soundingUntilMs = min(soundingUntilMs, endedMs) }
        }
    }
}

/// Пик громче — в звуке речь, тише — тишина или фон. По нему голосовое понимает, была ли речь,
/// а проверка очков — слышит ли их микрофон.
let speechPeakAmplitude = 600

/// Пик PCM s16le, 0..32767 (−32768 считается как 32767).
func peakAmplitude(_ pcm: Data) -> Int {
    var peak = 0
    pcm.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for sample in samples {
            let value = sample == Int16.min ? Int(Int16.max) : abs(Int(Int16(littleEndian: sample)))
            if value > peak { peak = value }
        }
    }
    return peak
}

private let log = Log("TonePlayer")
