import AVFoundation
import Combine
import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs

/// Взаимоисключение для async-кода: камеру включают и выключают строго по очереди.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}

/// Запуск Meta Wearables SDK: один раз на процесс, при старте приложения.
enum GlassesSdk {
    private(set) static var ready = false

    static func configure() {
        guard !ready else { return }
        do {
            try Wearables.configure()
            ready = true
            log.info("Meta Wearables SDK запущен")
        } catch {
            log.error("Meta Wearables SDK: \(error)")
        }
    }

    /// Meta AI возвращается в приложение по схеме qanatmobile:// — продолжить подключение очков или выдачу разрешения.
    static func handle(_ url: URL) {
        guard ready,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                log.warning("Meta AI вернул ошибку: \(error)")
            }
        }
    }
}

/// Кнопка камеры, связь и съёмка через Meta Wearables SDK (модули Inputs и Camera). Один экземпляр на приложение:
/// очки позволяют только одну сессию, и два владельца выталкивали бы друг друга.
final class MetaGlassesControls: GlassesControls, GlassesLink, GlassesCamera, GlassesAudioCapture,
    GlassesPermissions, GlassesPermissionRequester, GlassesRegistrationStatus, @unchecked Sendable {

    // MARK: Состояние

    private let registration = CurrentValueSubject<GlassesRegistrationState, Never>(.unavailable)
    private let registrationErrors = PassthroughSubject<GlassesRegistrationError, Never>()
    private let devices = CurrentValueSubject<[GlassesDeviceInfo], Never>([])
    private let gestureSubject = PassthroughSubject<GlassesGesture, Never>()
    let isLinked = CurrentValueSubject<Bool, Never>(false)
    let lastStart = CurrentValueSubject<GlassesLinkStart?, Never>(nil)
    let failure = CurrentValueSubject<GlassesLinkFailure?, Never>(nil)

    private let lock = NSLock()
    /// Сколько подписчиков держат сессию (кнопку очков); 0 — сессия не нужна.
    private var holders = 0
    private var sessionLoop: Task<Void, Never>?
    private var activeSession: DeviceSession?
    private var sessionGeneration = 0
    private var unlinkedAtMs: Int64?
    private var failedStarts = 0
    private var deviceTokens: [AnyListenerToken] = []
    private let presses: AsyncStream<CapturePress>
    private let pressContinuation: AsyncStream<CapturePress>.Continuation
    private let stateChanged = PassthroughSubject<Void, Never>()

    private let cameraMutex = AsyncMutex()
    private let photoMutex = AsyncMutex()
    private let videoMutex = AsyncMutex()
    private var activeCamera: ActiveCamera?
    private var recording: Recording?

    private static let sessionWait: Double = 15
    private static let retryDelay: Double = 3
    private static let failureRetryDelay: Double = 30
    private static let quickRetries = 3
    private static let streamStartTimeout: Double = 10
    // Полный снимок идёт по Bluetooth дольше кадра потока; не успел — снимаем из потока.
    private static let fullPhotoTimeout: Double = 30
    private static let firstKeyFrameTimeout: Double = 5
    // Звук не приходит дольше — поток замолчал. Первый звук приходит за ~2,3 с, дальше кадры — каждые 64 мс.
    private static let audioStallMs: Int64 = 5_000

    init() {
        (presses, pressContinuation) = AsyncStream.makeStream(of: CapturePress.self)
        // Нажатия всех сессий — в один распознаватель жестов.
        Task { [weak self, presses] in
            for await gesture in presses.gestures() { self?.gestureSubject.send(gesture) }
        }
        guard GlassesSdk.ready else { return }
        Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                let mapped = Self.registrationState(state)
                registration.send(mapped)
                // Ошибки сессий отвязанного Qanat ничего не говорят о следующей связи.
                if mapped != .registered { failure.send(nil) }
                stateChanged.send(())
            }
        }
        Task { [weak self] in
            for await identifiers in Wearables.shared.devicesStream() {
                self?.watchDevices(identifiers)
            }
        }
    }

    // MARK: GlassesControls

    var isRegistered: AnyPublisher<Bool, Never> {
        registration.map { $0 == .registered }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Пока на поток подписаны, держится сессия с очками; оборвалась — подключение повторяется само.
    var captureButtonGestures: AnyPublisher<GlassesGesture, Never> {
        gestureSubject
            .handleEvents(receiveSubscription: { [weak self] _ in self?.hold() }, receiveCancel: { [weak self] in self?.release() })
            .eraseToAnyPublisher()
    }

    /// Отвязанные очки SDK ещё помнит, но для Qanat их уже нет — поэтому без регистрации nil.
    var deviceInfo: AnyPublisher<GlassesDeviceInfo?, Never> {
        registration.combineLatest(devices)
            .map { state, all in state == .registered ? Self.preferred(all) : nil }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var currentDeviceInfo: GlassesDeviceInfo? {
        registration.value == .registered ? Self.preferred(devices.value) : nil
    }

    func awaitTakenOff() async {
        for await all in devices.values {
            let connected = all.filter(\.isConnected)
            if !connected.isEmpty && connected.allSatisfy({ $0.isWorn == false }) { return }
        }
    }

    // MARK: GlassesRegistrationStatus

    var state: AnyPublisher<GlassesRegistrationState, Never> { registration.removeDuplicates().eraseToAnyPublisher() }
    var errors: AnyPublisher<GlassesRegistrationError, Never> { registrationErrors.eraseToAnyPublisher() }

    /// Открывает Meta AI, где пользователь разрешает приложению работать с очками.
    func startRegistration() async {
        guard GlassesSdk.ready else { return }
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            log.warning("Meta SDK: ошибка регистрации \(error)")
            registrationErrors.send(String(describing: error).contains("alreadyRegistered") ? .alreadyRegistered : .other)
        }
    }

    /// Открывает Meta AI, где пользователь отвязывает приложение от очков.
    func startUnregistration() async {
        guard GlassesSdk.ready else { return }
        do {
            try await Wearables.shared.startUnregistration()
        } catch {
            log.warning("Meta SDK: ошибка отвязки \(error)")
            registrationErrors.send(String(describing: error).contains("alreadyUnregistered") ? .alreadyUnregistered : .other)
        }
    }

    /// Обновить прошивку очков или приложение Qanat на них — в Meta AI.
    func openGlassesUpdate(firmware: Bool) async {
        guard GlassesSdk.ready else { return }
        if firmware { try? await Wearables.shared.openFirmwareUpdate() } else { try? await Wearables.shared.openDATGlassesAppUpdate() }
    }

    // MARK: Разрешения

    /// Пока очки не на связи, SDK отвечает «не разрешено» и про выданное.
    func isGranted(_ permission: GlassesPermission) async -> Bool {
        guard GlassesSdk.ready else { return false }
        return (try? await Wearables.shared.checkPermissionStatus(Self.datPermission(permission))) == .granted
    }

    func request(_ permissions: [GlassesPermission]) async -> Bool {
        guard GlassesSdk.ready else { return permissions.isEmpty }
        for permission in permissions {
            guard (try? await Wearables.shared.requestPermission(Self.datPermission(permission))) == .granted else { return false }
        }
        return true
    }

    private static func datPermission(_ permission: GlassesPermission) -> MWDATCore.Permission {
        switch permission {
        case .camera: .camera
        case .microphone: .microphone
        }
    }

    // MARK: Очки и их состояние

    private func watchDevices(_ identifiers: [DeviceIdentifier]) {
        let found = identifiers.compactMap { Wearables.shared.deviceForIdentifier($0) }
        let tokens = found.map { device in
            device.addDeviceStateListener { [weak self] _ in self?.publishDevices(found) }
        }
        lock.withLock { deviceTokens = tokens }
        publishDevices(found)
    }

    private func publishDevices(_ found: [Device]) {
        devices.send(found.map(Self.info))
        stateChanged.send(())
    }

    private static func info(_ device: Device) -> GlassesDeviceInfo {
        let hinge = String(describing: device.hingeState).lowercased()
        let compatibility = device.compatibility()
        return GlassesDeviceInfo(
            name: device.name.isEmpty ? "Meta" : device.name,
            isConnected: device.linkState == .connected,
            // Пока очки не прислали заряд, SDK отдаёт пусто или 0 — это «неизвестно», а не разряжены.
            batteryLevel: device.batteryLevel.flatMap { $0 > 0 ? $0 : nil },
            isCharging: device.chargingState == .charging,
            isWorn: device.donState == .donned ? true : (device.donState == .doffed ? false : nil),
            isFolded: hinge.contains("closed") ? true : (hinge.contains("open") ? false : nil),
            updateRequired: compatibility == .deviceUpdateRequired ? .glasses : (compatibility == .sdkUpdateRequired ? .qanat : nil)
        )
    }

    /// Очки на связи, иначе первые известные.
    private static func preferred(_ all: [GlassesDeviceInfo]) -> GlassesDeviceInfo? {
        all.first(where: \.isConnected) ?? all.first
    }

    private static func registrationState(_ state: RegistrationState) -> GlassesRegistrationState {
        switch state {
        case .available: .available
        case .registering: .registering
        case .registered: .registered
        default: String(describing: state).lowercased().contains("unregistering") ? .unregistering : .unavailable
        }
    }

    // MARK: Сессия

    private func hold() {
        let start: Bool = lock.withLock {
            holders += 1
            return sessionLoop == nil
        }
        if start {
            let loop = Task { [weak self] in await self?.runSessions() }
            lock.withLock { sessionLoop = loop }
        }
    }

    private func release() {
        let loop: Task<Void, Never>? = lock.withLock {
            holders -= 1
            guard holders <= 0 else { return nil }
            defer { sessionLoop = nil }
            return sessionLoop
        }
        // Кнопку больше никто не слушает — сессию отпускаем, но не сразу: подписчик может вернуться.
        if let loop {
            Task {
                try? await Task.sleep(for: .seconds(5))
                if self.lock.withLock({ self.holders }) <= 0 { loop.cancel() } else { self.lock.withLock { self.sessionLoop = loop } }
            }
        }
    }

    private func runSessions() async {
        while !Task.isCancelled {
            guard registration.value == .registered else {
                await waitForChange(timeout: 3600)
                continue
            }
            // Снятые очки отклоняют сессию — ждём, пока их наденут.
            guard devices.value.contains(where: { $0.isConnected && $0.isWorn != false }) else {
                await waitForChange(timeout: 3600)
                continue
            }
            do {
                try await runSession()
            } catch is CancellationError {
                break
            } catch {
                log.info("Сессия с очками недоступна, повторим: \(error)")
            }
            failedStarts += 1
            // Первые попытки — быстрые: сразу после подключения в Meta AI очки отвечают «обновите приложение»,
            // пока Meta AI его доставляет. Сняли, надели или сложили очки — пробуем сразу.
            let slow = failure.value != nil && failedStarts > Self.quickRetries
            await waitForChange(timeout: slow ? Self.failureRetryDelay : Self.retryDelay)
        }
    }

    /// Ждёт смены регистрации или состояния очков, но не дольше [timeout].
    private func waitForChange(timeout: Double) async {
        let box = ResultBox<Void>()
        let subscription = stateChanged.dropFirst(0).first().sink { _ in box.set(()) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            box.set(nil)
        }
        await withTaskCancellationHandler { await box.wait() } onCancel: { box.set(nil) }
        timer.cancel()
        subscription.cancel()
    }

    /// Одна сессия с очками: кнопка камеры. Саму камеру включают только на время съёмки.
    private func runSession() async throws {
        let session = try Wearables.shared.createSession(deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))
        // Часть ошибок SDK шлёт прямо из start() и без повтора — слушаем с самого создания сессии.
        let errorsTask = Task { [weak self] in
            for await error in session.errorStream() {
                log.warning("Ошибка сессии с очками: \(error)")
                if let mapped = Self.linkFailure(error) { self?.failure.send(mapped) }
            }
        }
        defer { errorsTask.cancel() }
        let generation: Int = lock.withLock {
            sessionGeneration += 1
            activeSession = session
            return sessionGeneration
        }
        var linked = false
        defer {
            lock.withLock { if sessionGeneration == generation { activeSession = nil } }
            isLinked.send(false)
            if linked { unlinkedAtMs = uptimeMs() }
            try? session.removeInputs()
            session.stop()
        }
        try session.start()
        var started = false
        for await state in session.stateStream() {
            log.info("Сессия с очками: \(state)")
            if state == .started { started = true; break }
            if state == .stopped { break }
        }
        guard started else { throw GlassesStreamError("Сессия с очками не запустилась") }
        guard let inputs = try session.addInputs(configuration: InputsConfiguration(sources: [.captureButton], consumeBack: false)) else {
            throw GlassesStreamError("Кнопка очков не подключилась")
        }
        let pressesTask = Task { [pressContinuation] in
            for await event in inputs.events {
                guard case let .capture(pressType, _, timestamp) = event else { continue }
                log.debug("Кнопка камеры: \(pressType), t=\(timestamp) мс по часам очков")
                let name = String(describing: pressType).lowercased()
                pressContinuation.yield(name.contains("double") ? .double : (name.contains("hold") || name.contains("long") ? .hold : .short))
            }
        }
        defer { pressesTask.cancel() }
        // На связи — только когда кнопка уже слушается. Новая связь — только здесь, раз на сессию.
        let now = uptimeMs()
        lastStart.send(GlassesLinkStart(number: (lastStart.value?.number ?? 0) + 1, gapMs: unlinkedAtMs.map { now - $0 }))
        failure.send(nil)
        failedStarts = 0
        linked = true
        isLinked.send(true)
        // Касание с удержанием на дужке или снятие очков останавливают сессию — подключаемся заново.
        for await state in session.stateStream() {
            isLinked.send(state == .started)
            if state == .stopped { break }
        }
        throw GlassesStreamError("Сессия с очками остановлена")
    }

    /// Причина, которую может исправить пользователь; остальные ошибки — только в лог.
    private static func linkFailure(_ error: DeviceSessionError) -> GlassesLinkFailure? {
        if error == .datAppOnTheGlassesUpdateRequired { return .glassesAppOutdated }
        if error == .insufficientSDKVersion { return .qanatOutdated }
        let name = String(describing: error).lowercased()
        if name.contains("denied") { return .notAllowed }
        if name.contains("dwaunavailable") || name.contains("unavailable") && name.contains("dwa") { return .glassesAppUnavailable }
        if name.contains("battery") { return .batteryLow }
        if name.contains("thermal") || name.contains("peakpower") { return .overheated }
        return nil
    }

    /// Сессия с очками сейчас; если её нет — ждём до [timeout] с.
    private func currentSession(waiting timeout: Double = 0) async -> DeviceSession? {
        if let session = lock.withLock({ activeSession }), isLinked.value { return session }
        guard timeout > 0 else { return nil }
        hold()
        defer { release() }
        let deadline = uptimeMs() + Int64(timeout * 1000)
        while uptimeMs() < deadline {
            if let session = lock.withLock({ activeSession }), isLinked.value { return session }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    // MARK: Камера

    /// Включённая камера: пока она включена, на очках горит индикатор съёмки. [users] — сколько съёмок её держат.
    private final class ActiveCamera: @unchecked Sendable {
        let session: DeviceSession
        let camera: Camera
        let tokens = ListenerTokenBag()
        let audio: AudioTap?
        var users = 0
        var closed = false
        var streaming = false
        var over = false
        private let lock = NSLock()
        private var videoSubscribers: [UUID: (CMSampleBuffer) -> Void] = [:]

        init(session: DeviceSession, camera: Camera, audio: AudioTap?) {
            self.session = session
            self.camera = camera
            self.audio = audio
        }

        var stream: MWDATCamera.Stream { camera.stream }

        func subscribeVideo(_ handler: @escaping (CMSampleBuffer) -> Void) -> UUID {
            let id = UUID()
            lock.withLock { videoSubscribers[id] = handler }
            return id
        }

        func unsubscribeVideo(_ id: UUID) {
            lock.withLock { _ = videoSubscribers.removeValue(forKey: id) }
        }

        func deliver(_ sample: CMSampleBuffer) {
            let handlers = lock.withLock { Array(videoSubscribers.values) }
            handlers.forEach { $0(sample) }
        }
    }

    private struct Recording {
        let writer: GlassesVideoWriter
        let subscription: UUID
        let camera: ActiveCamera
    }

    /// Камера для снимка, когда полный снимок не вышел: поток сжатым — запись ждёт HEVC.
    private static let cameraConfig = StreamConfiguration(videoCodec: .hvc1, resolution: .medium, frameRate: 24)
    /// Видео кнопкой в галерею: HIGH (720×1280) — самое большое, что даёт SDK.
    private static let videoConfig = StreamConfiguration(videoCodec: .hvc1, resolution: .high, frameRate: 24)
    /// Камера голосового и разговора: снимки и «посмотри» берут кадр из её потока, видео Канату пишется с неё же.
    private static let voiceConfig = StreamConfiguration(
        videoCodec: .hvc1,
        audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
        resolution: .high,
        frameRate: 7
    )

    /// Новая камера в сессии; поток ещё не запущен, но на его кадры (и звук) уже подписаны.
    private func openCamera(_ session: DeviceSession, config: StreamConfiguration, withAudio: Bool, use: GlassesAudioUse = .note) throws -> ActiveCamera {
        guard let camera = try session.addCamera(config: config) else { throw GlassesStreamError("Камера очков не добавилась") }
        let active = ActiveCamera(session: session, camera: camera, audio: withAudio ? AudioTap(reorderWindow: use.reorderWindow) : nil)
        let stream = camera.stream
        // Ошибки запуска SDK шлёт прямо из start() и без повтора — подписываемся до него.
        stream.errorPublisher.listen { error in
            log.warning("Ошибка потока камеры: \(error)")
            active.audio?.record(String(describing: error).lowercased().contains("permission") ? .noPermission : .streamError)
        }.store(in: active.tokens)
        stream.statePublisher.listen { state in
            let name = String(describing: state).lowercased()
            if name.contains("streaming") { active.streaming = true }
            if name == "stopped" || name.contains("closed") { if active.streaming { active.over = true; active.audio?.lost() } }
        }.store(in: active.tokens)
        stream.videoFramePublisher.listen { frame in
            if let sample = frame.sampleBuffer as CMSampleBuffer? { active.deliver(sample) }
        }.store(in: active.tokens)
        if let tap = active.audio {
            stream.audioFramePublisher.listen { frame in
                tap.receive(frame.pcmBuffer, presentationUs: Self.micros(frame.presentationTimeStamp))
            }.store(in: active.tokens)
        }
        activeCamera = active
        return active
    }

    private static func micros(_ time: CMTime) -> Int64 { Int64(CMTimeGetSeconds(time) * 1_000_000) }
    private static func micros(_ seconds: Double) -> Int64 { Int64(seconds * 1_000_000) }

    /// Пока камера включена, на очках горит индикатор съёмки, — выключаем её, как только она никому не нужна.
    private func close(_ active: ActiveCamera) async {
        guard !active.closed else { return }
        active.closed = true
        if activeCamera === active { activeCamera = nil }
        // SDK требует отписать звук и остальные сборщики потока до camera.stop().
        await active.tokens.clear()
        active.audio?.finish()
        active.camera.stop()
        log.debug("Камера очков выключена")
    }

    private func release(_ active: ActiveCamera) async {
        await cameraMutex.withLock {
            active.users -= 1
            if active.users <= 0 { await close(active) }
        }
    }

    /// Ждёт, пока пойдёт поток. Бросает, если он остановился или не пошёл вовремя.
    private func awaitStreaming(_ active: ActiveCamera) async throws {
        let deadline = uptimeMs() + Int64(Self.streamStartTimeout * 1000)
        while !active.streaming {
            if active.over || uptimeMs() > deadline { throw GlassesStreamError("Поток камеры не запустился за \(Self.streamStartTimeout) с") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Камера жива: её сессия — текущая и поток не закрыт.
    private func isAlive(_ active: ActiveCamera?) -> Bool {
        guard let active, !active.closed, !active.over else { return false }
        return active.session === lock.withLock({ activeSession })
    }

    /// Включает камеру очков (или берёт уже включённую) и ждёт, пока пойдёт поток. На каждый вызов — один [release].
    /// [joinRunning] — только уже включённую камеру со звуком (голосового или разговора): свою не включать.
    private func acquireCamera(forVideo: Bool = false, joinRunning: Bool = false) async throws -> ActiveCamera {
        try await cameraMutex.withLock {
            guard let session = lock.withLock({ activeSession }) else { throw GlassesStreamError("Нет связи с очками — камера недоступна") }
            let reusable = isAlive(activeCamera) ? activeCamera : nil
            if joinRunning && reusable?.audio == nil { throw GlassesStreamError("Камера голосового или разговора не включена") }
            let active: ActiveCamera
            if let reusable {
                active = reusable
            } else {
                if let stale = activeCamera { await close(stale) }
                active = try openCamera(session, config: forVideo ? Self.videoConfig : Self.cameraConfig, withAudio: false)
                active.stream.start()
            }
            active.users += 1
            do {
                try await awaitStreaming(active)
            } catch {
                active.users -= 1
                if active.users <= 0 { await close(active) }
                throw error
            }
            return active
        }
    }

    // MARK: GlassesCamera

    var isRecordingVideo: Bool { lock.withLock { recording != nil } }

    func capturePhoto(full: Bool) async throws -> Data {
        try await photoMutex.withLock {
            if full, let photo = await fullPhotoIfIdle() { return photo }
            let active = try await acquireCamera()
            do {
                let photo = try await streamPhoto(active)
                await release(active)
                return photo
            } catch {
                await release(active)
                log.warning("Снимок не сделан: \(error)")
                throw error
            }
        }
    }

    /// Снимок из идущего потока: быстро, но в разрешении потока.
    private func streamPhoto(_ active: ActiveCamera) async throws -> Data {
        let box = ResultBox<Data>()
        let tokens = ListenerTokenBag()
        active.stream.photoDataPublisher.listen { photo in box.set(photo.data) }.store(in: tokens)
        defer { Task { await tokens.clear() } }
        guard active.stream.capturePhoto(format: .jpeg) else { throw GlassesStreamError("Очки не начали снимок") }
        let timer = Task {
            try? await Task.sleep(for: .seconds(10))
            box.set(nil)
        }
        await box.wait()
        timer.cancel()
        guard let data = box.value else { throw GlassesStreamError("Снимок не пришёл за 10 с") }
        return data
    }

    /// Снимок в полном разрешении камеры (отдельный режим фото SDK): кадр из потока мелкий, и мелкий текст документа
    /// агент читал с ошибками. Режим фото и поток делят камеру, поэтому, пока она занята, — nil.
    private func fullPhotoIfIdle() async -> Data? {
        await cameraMutex.withLock {
            guard let session = lock.withLock({ activeSession }) else { return nil }
            if isAlive(activeCamera) { return nil }
            if let stale = activeCamera { await close(stale) }
            guard let camera = try? session.addCamera(config: Self.cameraConfig) else {
                log.warning("Камера для полного снимка не добавилась")
                return nil
            }
            let photo = camera.photo
            let tokens = ListenerTokenBag()
            let result = ResultBox<Data>()
            let started = ResultBox<Bool>()
            // На данные и ошибки подписываемся до съёмки: SDK шлёт их без повтора.
            photo.photoDataPublisher.listen { capture in result.set(capture.imageData) }.store(in: tokens)
            photo.errorPublisher.listen { error in
                log.warning("Полный снимок не сделан: \(error)")
                started.set(false)
                result.set(nil)
            }.store(in: tokens)
            photo.statePublisher.listen { state in
                if String(describing: state).lowercased() == "started" { started.set(true) }
            }.store(in: tokens)
            defer {
                Task {
                    await tokens.clear()
                    photo.stop()
                    camera.stop()
                }
            }
            photo.start()
            let startTimer = Task {
                try? await Task.sleep(for: .seconds(Self.streamStartTimeout))
                started.set(nil)
            }
            await started.wait()
            startTimer.cancel()
            guard started.value == true else { return nil }
            let startedAt = uptimeMs()
            photo.capturePhoto(resolution: .full, quality: .high)
            let timer = Task {
                try? await Task.sleep(for: .seconds(Self.fullPhotoTimeout))
                result.set(nil)
            }
            await result.wait()
            timer.cancel()
            if let data = result.value {
                // Сколько идёт полный снимок — в release: по нему видно, стоит ли он ожидания.
                log.info("Полный снимок: \(data.count) байт за \(uptimeMs() - startedAt) мс")
            } else {
                log.warning("Полного снимка нет — снимаем из потока")
            }
            return result.value
        }
    }

    func startVideo(outputFile: URL, joinRunning: Bool) async throws {
        try await videoMutex.withLock {
            guard !isRecordingVideo else { throw GlassesStreamError("Запись уже идёт") }
            let writer = GlassesVideoWriter(output: outputFile)
            let active = try await acquireCamera(forVideo: true, joinRunning: joinRunning)
            let subscription = active.subscribeVideo { writer.write($0) }
            // Сигнал «запись пошла» звучит после этого: с идущего потока запись начнётся только с ключевого кадра.
            let ready = await withTimeout(seconds: Self.firstKeyFrameTimeout) { await writer.awaitFirstSample(); return true }
            guard ready != nil else {
                active.unsubscribeVideo(subscription)
                await release(active)
                writer.discard()
                throw GlassesStreamError("Ключевой кадр не пришёл за \(Self.firstKeyFrameTimeout) с")
            }
            lock.withLock { recording = Recording(writer: writer, subscription: subscription, camera: active) }
        }
    }

    // Начатую остановку доводим до конца: брошенная посередине запись оставила бы битый файл.
    func stopVideo() async throws -> URL {
        try await videoMutex.withLock {
            guard let active = lock.withLock({ recording }) else { throw GlassesStreamError("Запись не идёт") }
            lock.withLock { recording = nil }
            active.camera.unsubscribeVideo(active.subscription)
            await release(active.camera)
            return try await active.writer.finish()
        }
    }

    func awaitVideoInterrupted() async {
        guard let active = lock.withLock({ recording }) else { return }
        while isAlive(active.camera) && lock.withLock({ recording != nil }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: GlassesAudioCapture

    func startAudio(_ use: GlassesAudioUse) async -> GlassesAudioStart {
        guard let session = await currentSession(waiting: Self.sessionWait) else { return .failed(.notConnected) }
        guard await isGranted(.camera), await isGranted(.microphone) else { return .failed(.noPermission) }
        hold()
        do {
            return try await cameraMutex.withLock {
                // Живую камеру держит съёмка: свою камеру со звуком рядом не открыть, а выключать чужую нельзя.
                if isAlive(activeCamera) {
                    release()
                    return .failed(.busy)
                }
                if let stale = activeCamera { await close(stale) }
                let active = try openCamera(session, config: Self.voiceConfig, withAudio: true, use: use)
                active.users += 1
                let startedAt = uptimeMs()
                active.stream.start()
                do {
                    try await awaitStreaming(active)
                } catch {
                    active.users -= 1
                    await close(active)
                    release()
                    return .failed(active.audio?.error ?? .streamError)
                }
                return .started(MetaGlassesAudio(controls: self, active: active, startedAtMs: startedAt))
            }
        } catch {
            release()
            log.warning("Поток со звуком не запустился: \(error)")
            return .failed(.streamError)
        }
    }

    /// Звук камеры в порядке времени, без потерь, и первая ошибка её потока.
    final class AudioTap: @unchecked Sendable {
        let frames = AsyncQueue<GlassesAudioFrame>()
        private let lock = NSLock()
        private var reorder: PcmReorderBuffer
        private var index = 0
        private var converter: AVAudioConverter?
        private(set) var error: GlassesAudioError?
        private(set) var lastFrameAtMs: Int64 = 0
        private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

        init(reorderWindow: Int) { reorder = PcmReorderBuffer(window: reorderWindow) }

        func record(_ error: GlassesAudioError) {
            lock.withLock { if self.error == nil { self.error = error } }
        }

        /// В пути SDK только копируем кадр: сборщик, задержавшийся дольше кадра, иначе терял бы звук.
        func receive(_ buffer: AVAudioPCMBuffer, presentationUs: Int64) {
            let pcm: Data? = lock.withLock {
                if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
                return converter.flatMap { convert(buffer, with: $0, to: target) }
            }
            guard let pcm else { return }
            let now = uptimeMs()
            let ready: [GlassesAudioFrame] = lock.withLock {
                lastFrameAtMs = now
                defer { index += 1 }
                return reorder.push(GlassesAudioFrame(presentationTimeUs: presentationUs, pcm: pcm, arrivedAtMs: now, arrivalIndex: index))
            }
            ready.forEach { frames.send($0) }
        }

        /// Поток оборвался — звука больше не будет.
        func lost() {
            record(.streamError)
            finish()
        }

        /// Остаток по времени — и конец звука.
        func finish() {
            let rest = lock.withLock { reorder.drain() }
            rest.forEach { frames.send($0) }
            frames.finish()
        }
    }

    /// Идущий звук камеры: пока он идёт, держит общую сессию.
    private final class MetaGlassesAudio: GlassesAudio, @unchecked Sendable {
        private weak var controls: MetaGlassesControls?
        private let active: ActiveCamera
        let startedAtMs: Int64
        private let stopped = Locked(false)
        private var watcher: Task<Void, Never>?

        init(controls: MetaGlassesControls, active: ActiveCamera, startedAtMs: Int64) {
            self.controls = controls
            self.active = active
            self.startedAtMs = startedAtMs
            // Камера пропала или звук перестал приходить, хотя SDK о сбое молчит, — звука больше не будет.
            watcher = Task { [active] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let tap = active.audio else { return }
                    if active.over || active.closed || uptimeMs() - max(tap.lastFrameAtMs, startedAtMs) > MetaGlassesControls.audioStallMs {
                        log.warning("Звук с очков не приходит — поток замолчал")
                        tap.lost()
                        return
                    }
                }
            }
        }

        var frames: AsyncQueue<GlassesAudioFrame> { active.audio!.frames }
        var error: GlassesAudioError? { active.audio?.error }

        func liveFrames(intervalMs: Int64) -> AsyncStream<Data> {
            AsyncStream { continuation in
                let sampler = LiveFrameSampler(intervalMs: intervalMs) { continuation.yield($0) }
                let id = active.subscribeVideo { sampler.feed($0) }
                continuation.onTermination = { [active] _ in active.unsubscribeVideo(id) }
            }
        }

        /// Отписывается от звука, затем выключает камеру (так требует SDK). Повторный вызов ничего не делает.
        func stop() async {
            guard !stopped.value else { return }
            stopped.value = true
            watcher?.cancel()
            active.audio?.finish()
            // Камеру выключит последний, кто её держит: снимок, начатый во время голосового, её ещё не отпустил.
            await controls?.release(active)
            controls?.release()
        }
    }
}

private let log = Log("MetaGlassesControls")
