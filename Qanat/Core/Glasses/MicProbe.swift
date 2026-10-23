import Foundation

/// Замеры пробы микрофона очков. При ошибке — то, что успели записать до неё.
struct MicProbeResult: Equatable {
    /// WAV s16le, [glassesAudioSampleRate] Гц, моно; nil — файла нет (поток так и не открылся).
    let wavURL: URL?
    /// От запуска потока до первого кадра звука; nil — звука не было.
    let firstFrameLatencyMs: Int64?
    let frames: Int
    let totalSamples: Int
    let gaps: AudioGaps
    let error: MicProbeError?

    var durationMs: Int64 { Int64(totalSamples) * 1_000 / Int64(glassesAudioSampleRate) }

    static func failed(_ error: MicProbeError) -> MicProbeResult {
        MicProbeResult(wavURL: nil, firstFrameLatencyMs: nil, frames: 0, totalSamples: 0, gaps: .none, error: error)
    }
}

enum MicProbeError: Equatable {
    /// Очков нет на связи или Qanat не подключён к ним.
    case notConnected
    /// В Meta AI не разрешены камера или микрофон очков.
    case noPermission
    /// Камера очков занята записью видео или снимком.
    case cameraBusy
    /// Очки отклонили поток или он оборвался.
    case streamError
    /// Поток шёл, но звука не прислал.
    case noAudio
    /// Звук пришёл, но WAV не записался (например, нет места).
    case fileError
}

/// Разрывы звука и порядок кадров. [count] — сколько раз кадр начался позже, чем кончился предыдущий по времени,
/// [maxGapMs] — самый длинный такой разрыв. [outOfOrder] — сколько кадров пришло раньше уже полученного более
/// позднего кадра; [overlaps] — сколько кадров начались раньше, чем кончился предыдущий (повтор или наложение).
struct AudioGaps: Equatable {
    let count: Int
    let maxGapMs: Int64
    var outOfOrder = 0
    var overlaps = 0

    static let none = AudioGaps(count: 0, maxGapMs: 0)
}

/// Время кадра звука по часам потока и сколько в нём сэмплов (на канал).
struct AudioFrameTiming: Equatable {
    let presentationTimeUs: Int64
    let samples: Int
}

/// Разрывы по меткам времени кадров [frames] в порядке их прихода. Порядок прихода сверяем отдельно ([AudioGaps.outOfOrder]),
/// а разрывы и наложения ищем по кадрам, упорядоченным по времени, — так же, как они лягут в WAV.
/// Кадр должен начинаться там, где кончился предыдущий; расхождение больше [toleranceMs] — разрыв или наложение,
/// дрожание меток на пару миллисекунд ни тем, ни другим не является.
func findAudioGaps(_ frames: [AudioFrameTiming], sampleRate: Int, toleranceMs: Int64 = 10) -> AudioGaps {
    precondition(sampleRate > 0, "Частота должна быть положительной: \(sampleRate)")
    var outOfOrder = 0
    var latestUs = Int64.min
    for frame in frames {
        if frame.presentationTimeUs < latestUs { outOfOrder += 1 } else { latestUs = frame.presentationTimeUs }
    }
    var count = 0
    var overlaps = 0
    var maxGapUs: Int64 = 0
    let toleranceUs = toleranceMs * 1_000
    let sorted = frames.sorted { $0.presentationTimeUs < $1.presentationTimeUs }
    for (previous, next) in zip(sorted, sorted.dropFirst()) {
        let expectedUs = previous.presentationTimeUs + Int64(previous.samples) * 1_000_000 / Int64(sampleRate)
        let gapUs = next.presentationTimeUs - expectedUs
        if gapUs > toleranceUs {
            count += 1
            maxGapUs = max(maxGapUs, gapUs)
        } else if gapUs < -toleranceUs {
            overlaps += 1
        }
    }
    return AudioGaps(count: count, maxGapMs: maxGapUs / 1_000, outOfOrder: outOfOrder, overlaps: overlaps)
}

let wavHeaderSize = 44
private let maxWavDataBytes: Int64 = 0xFFFF_FFFF - Int64(wavHeaderSize)

/// Заголовок WAV (RIFF, PCM) длиной [wavHeaderSize] байт для [dataBytes] байт звука.
func wavHeader(dataBytes: Int64, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
    precondition((0...maxWavDataBytes).contains(dataBytes), "Размер данных вне WAV: \(dataBytes)")
    let blockAlign = channels * bitsPerSample / 8
    var data = Data(capacity: wavHeaderSize)
    func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func putInt(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func putShort(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    put("RIFF")
    putInt(UInt32(Int64(wavHeaderSize - 8) + dataBytes))
    put("WAVE")
    put("fmt ")
    putInt(16)
    putShort(1) // PCM
    putShort(UInt16(channels))
    putInt(UInt32(sampleRate))
    putInt(UInt32(sampleRate * blockAlign))
    putShort(UInt16(blockAlign))
    putShort(UInt16(bitsPerSample))
    put("data")
    putInt(UInt32(dataBytes))
    return data
}

/// Пишет PCM 16 бит [chunks] подряд в WAV [url] (создаёт каталог).
func writeWav(_ url: URL, chunks: [Data], sampleRate: Int, channels: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var file = wavHeader(dataBytes: Int64(chunks.reduce(0) { $0 + $1.count }), sampleRate: sampleRate, channels: channels, bitsPerSample: 16)
    for chunk in chunks { file.append(chunk) }
    try file.write(to: url, options: .atomic)
}

/// Проба микрофона очков через звук потока камеры Meta SDK ([GlassesAudioCapture]) — замеры для разработчиков.
/// Включает поток с PCM 16 кГц моно, пишет звук [durationSeconds] (считая с момента, когда поток пошёл) в WAV [outputURL]
/// и возвращает замеры. Не бросает: любой сбой — [MicProbeResult.error].
func probeGlassesMicrophone(_ audio: GlassesAudioCapture, durationSeconds: Double, outputURL: URL) async -> MicProbeResult {
    precondition(durationSeconds > 0, "Длительность пробы должна быть положительной: \(durationSeconds)")
    let stream: GlassesAudio
    switch await audio.startAudio(.note) {
    case .failed(let error):
        switch error {
        case .notConnected: return .failed(.notConnected)
        case .noPermission: return .failed(.noPermission)
        case .busy: return .failed(.cameraBusy)
        case .streamError: return .failed(.streamError)
        }
    case .started(let started): stream = started
    }
    let collected = Locked<[GlassesAudioFrame]>([])
    // Звук кончился раньше срока — очки отклонили поток, сняли или связь пропала.
    let broken = await withTimeout(seconds: durationSeconds) {
        while let frame = try await stream.frames.next() {
            collected.update { frames in
                if frames.count < loggedFrames {
                    probeLog.info("Кадр звука №\(frames.count + 1): \(frame.pcm.count) байт, t=\(frame.presentationTimeUs) мкс")
                }
                frames.append(frame)
            }
        }
        return true
    } ?? false
    await stream.stop()
    // Кадры, пришедшие до остановки, тоже в записи.
    while let frame = stream.frames.tryNext() { collected.update { $0.append(frame) } }
    let frames = collected.value
    var saved = false
    if !frames.isEmpty {
        do {
            try writeWav(outputURL, chunks: frames.map(\.pcm), sampleRate: glassesAudioSampleRate, channels: 1)
            saved = true
        } catch {
            probeLog.warning("WAV пробы не записался: \(error)")
        }
    }
    let streamError = stream.error
    let errorResult: MicProbeError? = if streamError == .noPermission {
        .noPermission
    } else if streamError != nil || broken {
        .streamError
    } else if frames.isEmpty {
        .noAudio
    } else if !saved {
        .fileError
    } else {
        nil
    }
    let byArrival = frames.sorted { $0.arrivalIndex < $1.arrivalIndex }
    let result = MicProbeResult(
        wavURL: saved ? outputURL : nil,
        firstFrameLatencyMs: byArrival.first.map { $0.arrivedAtMs - stream.startedAtMs },
        frames: frames.count,
        totalSamples: frames.reduce(0) { $0 + $1.samples },
        // Порядок прихода — по номеру кадра: выдаются кадры уже по времени.
        gaps: findAudioGaps(byArrival.map { AudioFrameTiming(presentationTimeUs: $0.presentationTimeUs, samples: $0.samples) }, sampleRate: glassesAudioSampleRate),
        error: errorResult
    )
    probeLog.info("Проба: первый звук через \(String(describing: result.firstFrameLatencyMs)) мс, кадров \(result.frames), сэмплов \(result.totalSamples) (\(result.durationMs) мс), разрывов \(result.gaps.count), наибольший \(result.gaps.maxGapMs) мс, не по порядку \(result.gaps.outOfOrder), наложений \(result.gaps.overlaps), ошибка \(String(describing: result.error))")
    return result
}

private let loggedFrames = 5
private let probeLog = Log("GlassesMicProbe")
