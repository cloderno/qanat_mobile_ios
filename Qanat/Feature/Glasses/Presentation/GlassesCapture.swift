import Foundation

/// Съёмка кнопкой камеры очков: одиночное нажатие — фото (или стоп записи, если идёт видео), удержание — старт видео.
/// Работает, пока пользователь авторизован, — с любого экрана. Снимок и видео, сделанные во время голосового или
/// разговора, уходят туда, куда указали [HandsFreeVoice.reservePhoto] и [HandsFreeVoice.reserveVideo] в момент нажатия.
/// Ошибки съёмки слышны сигналом — экрана может не быть.
@MainActor
final class GlassesCapture {
    private let glasses: GlassesControls
    private let camera: GlassesCamera
    private let repository: GlassesMediaRepository
    private let signals: GlassesSignals
    private let photos: PhotoRepository
    private let videos: VideoRepository
    private let voice: HandsFreeVoice

    /// Видео — от удержания до следующего одиночного нажатия, включая ещё не завершившийся старт.
    private var video: Recording?
    /// Видео только что остановилось само по пределу длины — одиночное нажатие, которым его хотели остановить, не снимок.
    private var stoppedByLimitUntil: Int64 = 0
    private var tasks: [Task<Void, Never>] = []

    /// Видео Канату — не длиннее: сервер принимает до 2 минут и 10 МБ.
    private static let videoToKanatMax: Double = 90
    /// После остановки по пределу нажатие в эти секунды — запоздалое «стоп», а не снимок.
    private static let afterLimitPressIgnoredMs: Int64 = 3_000

    private final class Recording {
        var start: Task<Void, Never>?
        let reservation: VideoReservation?
        init(reservation: VideoReservation?) { self.reservation = reservation }
    }

    private enum VideoEnd { case interrupted, commandEnded, limit }

    init(glasses: GlassesControls, camera: GlassesCamera, repository: GlassesMediaRepository, signals: GlassesSignals, photos: PhotoRepository, videos: VideoRepository, voice: HandsFreeVoice) {
        self.glasses = glasses
        self.camera = camera
        self.repository = repository
        self.signals = signals
        self.photos = photos
        self.videos = videos
        self.voice = voice
    }

    func run() async {
        for await gesture in glasses.captureButtonGestures.values {
            onGesture(gesture)
        }
        // Пользователь вышел: съёмку прошлого аккаунта не продолжаем и не сохраняем.
        tasks.forEach { $0.cancel() }
        await discardVideo()
    }

    private func onGesture(_ gesture: GlassesGesture) {
        // Жесты проверки очков засчитывает её экран; начатое видео одиночное нажатие останавливает и тогда.
        let practicing = voice.isPracticing
        switch gesture {
        case .singlePress:
            if video != nil {
                stopVideo(end: nil)
            } else if uptimeMs() < stoppedByLimitUntil {
                break
            } else if !practicing {
                takePhoto()
            }
        case .hold:
            if video == nil && !practicing { startVideo() }
        default:
            break
        }
    }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(Task { await body() })
    }

    private func takePhoto() {
        let reservation = voice.reservePhoto()
        launch {
            var photoId: String?
            defer { reservation?.set(photoId) }
            let jpeg: Data
            do {
                jpeg = try await self.camera.capturePhoto(full: true)
            } catch {
                await self.signals.play(.failed)
                return
            }
            // Сохранение идёт рядом с загрузкой: снимка ждёт голосовое или разговор.
            async let saved = self.save(jpeg)
            if reservation != nil {
                photoId = await self.upload(jpeg)
                reservation?.set(photoId)
            }
            if let media = await saved, let photoId { await self.repository.rememberServerCopy(media, serverId: photoId) }
        }
    }

    private func save(_ jpeg: Data) async -> CapturedMedia? {
        do {
            return try await repository.savePhoto(jpeg)
        } catch {
            log.warning("Снимок не сохранился в галерее приложения: \(error)")
            return nil
        }
    }

    /// Снимок к голосовому или разговору. UUID на сервере, nil — не загрузился (сигнал уже прозвучал).
    private func upload(_ jpeg: Data) async -> String? {
        do {
            return try await photos.upload(jpeg: jpeg, source: .glasses)
        } catch {
            log.warning("Не удалось отправить снимок агенту: \(error)")
            await signals.play(.failed)
            return nil
        }
    }

    private func startVideo() {
        let slot = voice.reserveVideo()
        let reservation: VideoReservation?
        var joinRunning = false
        switch slot {
        case .gallery:
            reservation = nil
        // Видео к голосовому уже есть — второе не снимаем, а не пишем молча только в галерею.
        case .taken:
            launch { await self.signals.play(.failed) }
            return
        // Видео команде пишется только с её камеры; разговор с микрофона телефона камеру очков не включает.
        case .forCommand(let command, let ownCamera):
            reservation = command
            joinRunning = !ownCamera
        }
        let recording = Recording(reservation: reservation)
        video = recording
        recording.start = Task {
            do {
                try await self.camera.startVideo(outputFile: self.repository.newVideoTempFile(), joinRunning: joinRunning)
            } catch {
                if self.video === recording { self.video = nil }
                reservation?.fail()
                if !(error is CancellationError) { await self.signals.play(.failed) }
                return
            }
            // Команда кончилась, пока запись ждала ключевой кадр: «видео пошло» после её сигнала конца обмануло бы.
            if Task.isCancelled { return }
            if reservation?.isCommandOver == true {
                if self.video === recording { self.video = nil }
                reservation?.fail()
                if let file = try? await self.camera.stopVideo() { try? FileManager.default.removeItem(at: file) }
                await self.signals.play(.failed)
                return
            }
            await self.signals.play(.videoStarted)
            let end = await self.awaitVideoEnd(reservation)
            if !Task.isCancelled, self.video === recording { self.stopVideo(end: end) }
        }
    }

    /// Ждёт, пока запись кончится сама: очки сняли или связь пропала; команда закончилась; видео Канату дошло до предела.
    private func awaitVideoEnd(_ reservation: VideoReservation?) async -> VideoEnd {
        let box = ResultBox<VideoEnd>()
        let interrupted = Task { await self.camera.awaitVideoInterrupted(); box.set(.interrupted) }
        var others: [Task<Void, Never>] = []
        if let reservation {
            others.append(Task { await reservation.awaitCommandEnd(); box.set(.commandEnded) })
            others.append(Task {
                try? await Task.sleep(for: .seconds(Self.videoToKanatMax))
                if !Task.isCancelled { box.set(.limit) }
            })
        }
        await withTaskCancellationHandler { await box.wait() } onCancel: { box.set(nil) }
        interrupted.cancel()
        others.forEach { $0.cancel() }
        return box.value ?? .interrupted
    }

    /// [end] — почему запись кончилась сама; nil — её остановили нажатием.
    private func stopVideo(end: VideoEnd?) {
        guard let recording = video else { return }
        video = nil
        if end == .limit { stoppedByLimitUntil = uptimeMs() + Self.afterLimitPressIgnoredMs }
        launch {
            defer { recording.reservation?.fail() }
            // Нажатие, пока старт ещё идёт, — это стоп, а не снимок: старт отменяем, записи не будет.
            recording.start?.cancel()
            await recording.start?.value
            // Команда кончилась — о её конце уже говорит её собственный сигнал.
            if end != .commandEnded { await self.signals.play(.videoStopped) }
            guard self.camera.isRecordingVideo else { return }
            let file: URL
            do {
                file = try await self.camera.stopVideo()
            } catch {
                await self.signals.play(.failed)
                return
            }
            guard let media = try? await self.repository.saveVideo(file) else { return }
            if let reservation = recording.reservation { await self.send(media, reservation) }
        }
    }

    /// Видео — команде, пока она его ждёт. Не дождалась — копия у Каната ни к чему не приложена: убираем её.
    private func send(_ media: CapturedMedia, _ reservation: VideoReservation) async {
        guard reservation.isWanted else { return }
        let videoId: String
        do {
            videoId = try await videos.upload(video: media.file)
        } catch {
            log.warning("Не удалось отправить видео Канату: \(error)")
            await signals.play(.failed)
            return
        }
        if reservation.complete(videoId) {
            await repository.rememberServerCopy(media, serverId: videoId)
            return
        }
        do {
            try await videos.delete(id: videoId)
        } catch {
            log.warning("Видео \(videoId), которое уже не нужно, у Каната не удалилось: \(error)")
        }
    }

    // Запись могла остаться и без video: выход из аккаунта отменил её остановку на полпути.
    private func discardVideo() async {
        if let recording = video {
            video = nil
            recording.start?.cancel()
            await recording.start?.value
            recording.reservation?.fail()
        }
        if camera.isRecordingVideo, let file = try? await camera.stopVideo() {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private let log = Log("GlassesCapture")
