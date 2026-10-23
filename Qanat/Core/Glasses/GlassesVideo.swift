import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// Склеивает сжатые HEVC-кадры потока очков в mp4 без перекодирования — кадры уже в этом формате.
/// Запись начинается с ключевого кадра: без него начало не декодируется (подписаться можно и посреди потока).
final class GlassesVideoWriter: @unchecked Sendable {
    private let output: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var samples = 0
    private var received = 0
    private var beforeKeyFrame = 0
    private var firstSampleBox = ResultBox<Void>()

    init(output: URL) {
        self.output = output
        try? FileManager.default.removeItem(at: output)
    }

    /// Завершается, когда в файл лёг первый кадр: запись с идущего потока ждёт ключевого кадра.
    func awaitFirstSample() async { await firstSampleBox.wait() }

    func write(_ sample: CMSampleBuffer) {
        lock.withLock {
            received += 1
            if writer == nil {
                guard Self.isKeyFrame(sample) else {
                    beforeKeyFrame += 1
                    return
                }
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let created = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return }
                // Passthrough: outputSettings = nil, формат кодека берём из самого кадра (VPS/SPS/PPS).
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                videoInput.expectsMediaDataInRealTime = true
                guard created.canAdd(videoInput) else { return }
                created.add(videoInput)
                guard created.startWriting() else {
                    log.warning("Запись видео не открылась: \(String(describing: created.error))")
                    return
                }
                created.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                writer = created
                input = videoInput
            }
            guard let input, input.isReadyForMoreMediaData else { return }
            if input.append(sample) {
                samples += 1
                if samples == 1 { firstSampleBox.set(()) }
            }
        }
    }

    /// Закрывает файл. Запись без единого кадра не сохраняется: файл удаляется, а вызывающий получает ошибку.
    func finish() async throws -> URL {
        let (writer, input, samples) = lock.withLock { (self.writer, self.input, self.samples) }
        guard let writer, let input, samples > 0 else {
            discard()
            throw GlassesStreamError("В записи нет ни одного кадра: получено \(received), до ключевого кадра \(beforeKeyFrame)")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            discard()
            throw writer.error ?? GlassesStreamError("Видео не сохранилось")
        }
        log.info("Видео записано: кадров \(samples); пропущено до ключевого кадра \(beforeKeyFrame)")
        return output
    }

    /// Бросает запись: освобождает writer и удаляет файл.
    func discard() {
        lock.withLock {
            writer?.cancelWriting()
            writer = nil
            input = nil
        }
        try? FileManager.default.removeItem(at: output)
    }

    /// Ключевой кадр: у него нет отметки NotSync.
    static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}

struct GlassesStreamError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Редкие JPEG-кадры из идущего видео очков — «живые кадры» Канату в разговоре. Видео приходит сжатым в HEVC,
/// поэтому его декодирует аппаратный декодер, а в JPEG собирается не больше кадра в [intervalMs].
/// Не вышло декодировать — поток кадров просто кончается: разговор идёт и без них.
final class LiveFrameSampler: @unchecked Sendable {
    private let intervalMs: Int64
    private let onJpeg: (Data) -> Void
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var waitKeyFrame = true
    private var lastSampleAt = Int64.min / 2
    private let context = CIContext()
    private static let jpegQuality = 0.7

    init(intervalMs: Int64, onJpeg: @escaping (Data) -> Void) {
        self.intervalMs = intervalMs
        self.onJpeg = onJpeg
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func feed(_ sample: CMSampleBuffer) {
        lock.withLock {
            guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else { return }
            if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: sampleFormat) }) == true {
                makeSession(sampleFormat)
                waitKeyFrame = true
            }
            guard let session else { return }
            let keyFrame = GlassesVideoWriter.isKeyFrame(sample)
            if waitKeyFrame && !keyFrame { return }
            waitKeyFrame = false
            // Декодируем каждый кадр (иначе следующие декодировались бы с мусором), а JPEG — не чаще интервала.
            let wanted = uptimeMs() - lastSampleAt >= intervalMs
            if wanted { lastSampleAt = uptimeMs() }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                guard wanted, status == noErr, let image, let self else { return }
                let ciImage = CIImage(cvPixelBuffer: image)
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let jpeg = self.context.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Self.jpegQuality])
                else { return }
                self.onJpeg(jpeg)
            }
            if status != noErr {
                // Декодер занят или поток битый — ждём ключевой кадр.
                waitKeyFrame = true
            }
        }
    }

    private func makeSession(_ newFormat: CMFormatDescription) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = newFormat
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        if status == noErr {
            session = created
        } else {
            // В release: без этого не понять, почему Канат перестал видеть.
            log.warning("Живые кадры остановлены: видео очков не декодируется (\(status))")
        }
    }
}

private let log = Log("GlassesVideo")
