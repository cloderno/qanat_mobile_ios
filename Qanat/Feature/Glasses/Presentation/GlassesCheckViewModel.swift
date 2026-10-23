import Combine
import Foundation

/// Шаги проверки очков — в этом порядке.
enum GlassesCheckStep: Int, CaseIterable { case link, button, microphone, speaker, camera }

/// Жесты шага «Кнопка» — в этом порядке.
let checkGestures: [GlassesGesture] = [.singlePress, .clickAndHold, .doublePress, .triplePress]

/// Почему шаг не прошёл — у каждого шага свои причины.
enum CheckFailure: Equatable {
    case link(LinkProblem)
    /// Qanat не на связи с очками, пока идёт шаг «Кнопка»: нажатия уходят в Meta AI, а не в проверку.
    case buttonNotConnected
    case microphone(MicrophoneFailure)
    case speakerNotHeard
    case camera(CameraFailure)
}

/// Что мешает связи Qanat с очками; порядок — от самой вероятной причины, см. [linkProblem].
enum LinkProblem: Equatable {
    case bluetoothOff
    /// Qanat не подключён к очкам в Meta AI.
    case notRegistered
    /// Meta AI не знает ни одних очков.
    case noGlasses
    /// Дужки сложены (или были сложены, когда очки пропали со связи).
    case folded
    /// Очки не на связи с телефоном: выключены, в футляре, далеко.
    case offline
    /// Очки не поддерживают эту версию Qanat.
    case qanatUpdate
    /// Прошивка очков старше, чем нужна Qanat.
    case glassesUpdate
    /// Сняты: снятые очки сессию отклоняют.
    case takenOff
    // Дальше — по ошибке последней попытки связи ([GlassesLinkFailure]).
    /// Очки отклонили Qanat как неразрешённый.
    case notAllowed
    /// Приложению Qanat на очках нужно обновление.
    case glassesAppUpdate
    /// Приложение Qanat на очках не запустилось.
    case glassesAppUnavailable
    case lowBattery
    case overheated
    /// Всё, что видно телефону, в порядке, а связи нет.
    case unknown
}

enum MicrophoneFailure: Equatable {
    case noAccess
    case notConnected
    /// Камеру очков держит видео, голосовое или разговор: их останавливает кнопка очков и во время проверки.
    case busy
    case streamError
    /// Звук шёл, а речи за [GlassesCheckViewModel.micListenSeconds] не было.
    case silent
}

enum CameraFailure: Equatable {
    case noAccess
    /// Qanat не на связи с очками.
    case notConnected
    case failed
}

/// Чем кончился шаг.
enum CheckResult: Equatable {
    case passed
    case failed(CheckFailure)
    case skipped
}

/// Что сейчас на экране проверки. Пройденный шаг ещё немного стоит на экране — уже с итогом в [GlassesCheckUiState.results].
enum CheckStage: Equatable {
    /// Ждём сессию с очками; [problem] — что ей мешает, когда за [GlassesCheckViewModel.linkTimeout] её так и нет.
    case link(problem: LinkProblem? = nil)
    /// [done] — сколько жестов из [checkGestures] уже распознано; [mismatch] — нажали не тот жест.
    case button(done: Int = 0, mismatch: GlassesGesture? = nil, notConnected: Bool = false)
    /// До [listening] поток со звуком запускается; [level] — громкость звука, 0..1 ([micLevel]).
    case microphone(listening: Bool = false, level: Float = 0, failure: MicrophoneFailure? = nil)
    /// [playing] — сигнал звучит; после него ждём ответа, слышно ли.
    case speaker(playing: Bool = true, notHeard: Bool = false)
    /// Снимаем, пока нет ни снимка, ни [failure].
    case camera(failure: CameraFailure? = nil)
    case summary

    /// Шаг на экране; nil — итог проверки.
    var step: GlassesCheckStep? {
        switch self {
        case .link: .link
        case .button: .button
        case .microphone: .microphone
        case .speaker: .speaker
        case .camera: .camera
        case .summary: nil
        }
    }

    /// Почему шаг сейчас не проходит; nil — идёт или прошёл.
    var failure: CheckFailure? {
        switch self {
        case .link(let problem): problem.map { .link($0) }
        case .button(_, _, let notConnected): notConnected ? .buttonNotConnected : nil
        case .microphone(_, _, let failure): failure.map { .microphone($0) }
        case .speaker(_, let notHeard): notHeard ? .speakerNotHeard : nil
        case .camera(let failure): failure.map { .camera($0) }
        case .summary: nil
        }
    }

    /// Какой жест ждёт шаг «Кнопка»; nil — распознаны все или шаг другой.
    var expectedGesture: GlassesGesture? {
        guard case .button(let done, _, _) = self, done < checkGestures.count else { return nil }
        return checkGestures[done]
    }

    static func first(of step: GlassesCheckStep?) -> CheckStage {
        switch step {
        case .link: .link()
        case .button: .button()
        case .microphone: .microphone()
        case .speaker: .speaker()
        case .camera: .camera()
        case nil: .summary
        }
    }
}

struct GlassesCheckUiState: Equatable {
    var stage: CheckStage = .link()
    var results: [GlassesCheckStep: CheckResult] = [:]
    /// Снимок шага «Камера» — его превью на шаге и в итоге.
    var photo: Data?

    /// Шаг на экране уже прошёл — секунда, чтобы увидеть галочку, перед следующим.
    var stagePassed: Bool { stage.step.flatMap { results[$0] } == .passed }
}

/// Самая вероятная причина, почему Qanat не на связи с очками, — по тому, что видно телефону: каждая следующая
/// проверяется, только если нет предыдущих. Ошибку последней попытки ([failure]) — после состояния очков: снятые или
/// отключённые очки новой попытки не дают, и прошлая ошибка уже не причина. Доступ к камере и микрофону очков связи
/// не нужен — его проверяют свои шаги.
func linkProblem(bluetoothOn: Bool, registered: Bool, device: GlassesDeviceInfo?, failure: GlassesLinkFailure?) -> LinkProblem {
    guard bluetoothOn else { return .bluetoothOff }
    guard registered else { return .notRegistered }
    guard let device else { return .noGlasses }
    // Сложенные очки рвут связь с телефоном — поэтому раньше «не на связи».
    if device.isFolded == true { return .folded }
    if !device.isConnected { return .offline }
    if device.updateRequired == .qanat { return .qanatUpdate }
    if device.updateRequired == .glasses { return .glassesUpdate }
    if device.isWorn == false { return .takenOff }
    switch failure {
    case .notAllowed: return .notAllowed
    case .glassesAppOutdated: return .glassesAppUpdate
    case .glassesAppUnavailable: return .glassesAppUnavailable
    case .qanatOutdated: return .qanatUpdate
    case .batteryLow: return .lowBattery
    case .overheated: return .overheated
    case nil: return .unknown
    }
}

/// Громкость для шкалы микрофона, 0..1: пик в дБ от −levelRangeDb (тишина) до 0 — так заметна и тихая речь.
func micLevel(_ peak: Int) -> Float {
    guard peak > 0 else { return 0 }
    let db = 20 * log10(Double(peak) / Double(Int16.max))
    return Float(min(max(1 + db / levelRangeDb, 0), 1))
}

private let levelRangeDb = 60.0

extension GlassesAudioError {
    var microphoneFailure: MicrophoneFailure {
        switch self {
        case .notConnected: .notConnected
        case .noPermission: .noAccess
        case .busy: .busy
        case .streamError: .streamError
        }
    }
}

/// Проверка очков по шагам ([GlassesCheckStep]): связь, кнопка, микрофон, звук и камера. Каждый шаг можно пропустить
/// и повторить; в конце — итог. Камеру очков (и с ней индикатор на них) включают только шаги микрофона и камеры —
/// и только пока идут.
///
/// Пока экран на виду, жесты кнопки засчитывает проверка, а сами они ничего не запускают — только останавливают уже
/// начатые видео, голосовое или разговор ([HandsFreeVoice.isPracticing]): иначе камера очков осталась бы занятой.
/// [onVisible]/[onHidden] — пока он на виду, [restart] — новый заход.
@MainActor
@Observable
final class GlassesCheckViewModel {
    private(set) var state = GlassesCheckUiState()

    @ObservationIgnored private let glasses: GlassesControls
    @ObservationIgnored private let link: GlassesLink
    @ObservationIgnored private let bluetooth: PhoneBluetooth
    @ObservationIgnored private let permissions: GlassesPermissions
    @ObservationIgnored private let audio: GlassesAudioCapture
    @ObservationIgnored private let camera: GlassesCamera
    @ObservationIgnored private let signals: GlassesSignals
    @ObservationIgnored private let voice: HandsFreeVoice

    @ObservationIgnored private var visible = false
    @ObservationIgnored private var listening: AnyCancellable?
    /// Дело шага на экране: ждать связь, следить за ней на шаге кнопки, слушать микрофон, играть сигнал, снимать — или
    /// выдержать паузу после «прошёл».
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Одиночное нажатие вместо клика + удержания, о котором скажем, если удержание так и не придёт ([onGesture]).
    @ObservationIgnored private var pendingMismatch: Task<Void, Never>?

    /// Столько ждём сессию с очками, прежде чем искать, что ей мешает.
    static let linkTimeout: Duration = .seconds(20)
    /// Столько слушаем речь в микрофоне очков, когда звук уже пошёл.
    static let micListenSeconds: Double = 10
    /// Столько пройденный шаг ещё на экране.
    static let passPause: Duration = .seconds(1)

    init(
        glasses: GlassesControls,
        link: GlassesLink,
        bluetooth: PhoneBluetooth,
        permissions: GlassesPermissions,
        audio: GlassesAudioCapture,
        camera: GlassesCamera,
        signals: GlassesSignals,
        voice: HandsFreeVoice
    ) {
        self.glasses = glasses
        self.link = link
        self.bluetooth = bluetooth
        self.permissions = permissions
        self.audio = audio
        self.camera = camera
        self.signals = signals
        self.voice = voice
    }

    /// Проверка с первого шага.
    func restart() {
        state = GlassesCheckUiState()
        enter(.link)
    }

    /// Экран на виду: жесты засчитываются, а не выполняются, и идёт дело текущего шага.
    func onVisible() {
        guard !visible else { return }
        visible = true
        voice.isPracticing = true
        bluetooth.start()
        // Пока жесты слушают, держится и сессия с очками — без неё шагу связи нечего ждать.
        listening = glasses.captureButtonGestures.receive(on: DispatchQueue.main).sink { [weak self] in self?.onGesture($0) }
        run()
    }

    /// Экран закрыли или приложение свернули: кнопка очков снова работает по-настоящему, а микрофон, сигнал и камера
    /// выключаются — их шаг начнётся заново, когда экран вернётся.
    func onHidden() {
        guard visible else { return }
        visible = false
        listening?.cancel()
        listening = nil
        work?.cancel()
        work = nil
        pendingMismatch?.cancel()
        pendingMismatch = nil
        voice.isPracticing = false
    }

    /// «Пропустить»: шаг остаётся непроверенным.
    func skip() { finish(.skipped) }

    /// «Дальше» после неудачи: её причина остаётся в итоге.
    func onNext() {
        guard let failure = state.stage.failure else { return }
        finish(.failed(failure))
    }

    /// «Повторить»: шаг на экране — с начала.
    func retry() {
        guard let step = state.stage.step, state.results[step] == nil else { return }
        enter(step)
    }

    /// «Повторить» в итоге: только этот шаг, а потом снова итог.
    func retryStep(_ step: GlassesCheckStep) {
        guard state.stage == .summary else { return }
        state.results[step] = nil
        enter(step)
    }

    /// Ответ на «Слышите сигнал в очках?». Куда ушёл звук, телефон не проверяет: сигнал из динамика телефона —
    /// это «нет», а подсказка к нему — про звук мультимедиа у очков.
    func onSignalHeard(_ heard: Bool) {
        guard case .speaker = state.stage, !state.stagePassed else { return }
        if heard {
            passNow(.speaker)
        } else {
            work?.cancel()
            work = nil
            state.stage = .speaker(playing: false, notHeard: true)
        }
    }

    /// Подсказку о неверном жесте показали — прячем.
    func onMismatchShown() {
        if case .button(let done, _, let notConnected) = state.stage {
            state.stage = .button(done: done, mismatch: nil, notConnected: notConnected)
        }
    }

    private func finish(_ result: CheckResult) {
        guard let step = state.stage.step, state.results[step] == nil else { return }
        state.results[step] = result
        advance()
    }

    /// Следующий шаг без итога: по порядку, а после повтора из итога — снова итог.
    private func advance() {
        enter(GlassesCheckStep.allCases.first { state.results[$0] == nil })
    }

    private func enter(_ step: GlassesCheckStep?) {
        work?.cancel()
        work = nil
        pendingMismatch?.cancel()
        pendingMismatch = nil
        state.stage = .first(of: step)
        if step == .camera { state.photo = nil }
        run()
    }

    /// Запускает дело шага на экране, если оно у него есть и ещё не кончилось.
    private func run() {
        guard visible else { return }
        // Пауза после «прошёл» прервалась вместе с экраном — сразу дальше.
        if state.stagePassed {
            advance()
            return
        }
        work?.cancel()
        switch state.stage {
        case .link(let problem): work = Task { await checkLink(shown: problem) }
        case .button: work = Task { await watchButtonLink() }
        case .microphone(_, _, let failure): work = failure == nil ? Task { await checkMicrophone() } : nil
        case .speaker(let playing, _): work = playing ? Task { await playSignal() } : nil
        case .camera(let failure): work = failure == nil ? Task { await checkCamera() } : nil
        case .summary: work = nil
        }
    }

    /// Шаг прошёл: итог сразу в списке, а сам шаг ещё [passPause] на экране — успеть увидеть галочку.
    private func pass(_ step: GlassesCheckStep) async {
        state.results[step] = .passed
        try? await Task.sleep(for: Self.passPause)
        guard !Task.isCancelled else { return }
        advance()
    }

    /// [pass] для шага, который проходит по событию — жесту или ответу, — а не в своём деле.
    private func passNow(_ step: GlassesCheckStep) {
        work?.cancel()
        work = Task { await pass(step) }
    }

    /// Ждёт сессию с очками; не дождавшись за [linkTimeout], показывает самую вероятную причину — и ждёт дальше.
    /// [shown] — причина, которая уже была на экране (экран вернулся): тогда новое ожидание не нужно.
    private func checkLink(shown: LinkProblem?) async {
        let waited = CurrentValueSubject<Bool, Never>(shown != nil)
        let timer = shown == nil ? Task {
            try? await Task.sleep(for: Self.linkTimeout)
            if !Task.isCancelled { waited.send(true) }
        } : nil
        let diagnosis = linkProblems(shown: shown)
            .combineLatest(waited)
            .map { problem, show in show ? problem : nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] problem in
                guard let self, case .link = self.state.stage else { return }
                self.state.stage = .link(problem: problem)
            }
        defer {
            timer?.cancel()
            diagnosis.cancel()
        }
        for await linked in link.isLinked.values where linked { break }
        guard !Task.isCancelled else { return }
        await pass(.link)
    }

    /// Qanat ещё секунды подключается к очкам, а после неудачной попытки и ждёт перед следующей, — поэтому сначала
    /// nil (снова ждём), и «непонятно почему», только если связи нет и через [linkTimeout]. [shown] — причина,
    /// которая была на экране до этого.
    private func linkProblems(shown: LinkProblem?) -> AnyPublisher<LinkProblem?, Never> {
        var last = shown
        return bluetooth.isOn
            .combineLatest(glasses.isRegistered, glasses.deviceInfo, link.failure)
            .map { linkProblem(bluetoothOn: $0, registered: $1, device: $2, failure: $3) }
            .removeDuplicates()
            .map { problem -> AnyPublisher<LinkProblem?, Never> in
                let fixed = problem == .unknown && last != nil && last != .unknown
                last = problem
                guard fixed else { return Just(problem).eraseToAnyPublisher() }
                return Just(problem)
                    .delay(for: .seconds(20), scheduler: DispatchQueue.main)
                    .prepend(nil)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    /// Без связи нажатия уходят в Meta AI — снимок, видео, — а не в проверку: пока её нет, шаг так и говорит.
    private func watchButtonLink() async {
        for await linked in link.isLinked.values {
            guard case .button(let done, let mismatch, _) = state.stage else { return }
            state.stage = .button(done: done, mismatch: mismatch, notConnected: !linked)
        }
    }

    private func onGesture(_ gesture: GlassesGesture) {
        guard case .button(let done, _, let notConnected) = state.stage, let expected = state.stage.expectedGesture else { return }
        pendingMismatch?.cancel()
        pendingMismatch = nil
        if gesture == expected {
            state.stage = .button(done: done + 1, mismatch: nil, notConnected: notConnected)
            if state.stage.expectedGesture == nil { passNow(.button) }
        } else if expected == .clickAndHold && gesture == .singlePress {
            // При клике + удержании обычной длины клик становится одиночным нажатием раньше, чем отпустят удержание
            // (см. GestureRecognizer), — «не тот жест» говорим, только если удержание за клик так и не пришло.
            pendingMismatch = Task {
                try? await Task.sleep(for: .milliseconds(GestureRecognizer.lateClickAndHoldMs))
                guard !Task.isCancelled, case .button(let done, _, let notConnected) = state.stage else { return }
                state.stage = .button(done: done, mismatch: gesture, notConnected: notConnected)
            }
        } else {
            state.stage = .button(done: done, mismatch: gesture, notConnected: notConnected)
        }
    }

    private func checkMicrophone() async {
        updateMicrophone { _ in .microphone() }
        if let failure = await listen() {
            guard !Task.isCancelled else { return }
            updateMicrophone { _ in .microphone(failure: failure) }
        } else {
            await pass(.microphone)
        }
    }

    /// Ждёт речи в микрофоне очков не дольше [micListenSeconds] и выключает его. Возвращает nil — речь услышали.
    private func listen() async -> MicrophoneFailure? {
        let stream: GlassesAudio
        switch await audio.startAudio(.note) {
        case .failed(let error): return error.microphoneFailure
        case .started(let audio): stream = audio
        }
        updateMicrophone { _ in .microphone(listening: true) }
        let heard: Bool? = await withTimeout(seconds: Self.micListenSeconds) { [weak self] in
            while let frame = try? await stream.frames.next() {
                let peak = peakAmplitude(frame.pcm)
                await MainActor.run { self?.updateMicrophone { _ in .microphone(listening: true, level: micLevel(peak)) } }
                if peak > speechPeakAmplitude { return true }
            }
            return false
        }
        let error = stream.error
        await stream.stop()
        switch heard {
        case true: return nil
        case nil: return .silent
        // Звук кончился сам: поток оборвался или доступ к микрофону отозвали.
        case false: return error?.microphoneFailure ?? .streamError
        }
    }

    private func playSignal() async {
        if case .speaker = state.stage { state.stage = .speaker(playing: true) }
        await signals.play(.check)
        guard !Task.isCancelled, case .speaker(_, let notHeard) = state.stage else { return }
        state.stage = .speaker(playing: false, notHeard: notHeard)
    }

    private func checkCamera() async {
        // Пока очки не на связи, SDK и про выданный доступ отвечает «нет» — спрашивать его тогда незачем.
        let connected = glasses.currentDeviceInfo?.isConnected == true
        if connected, !(await permissions.isGranted(.camera)) {
            if case .camera = state.stage { state.stage = .camera(failure: .noAccess) }
            return
        }
        // Проверке важно, что камера снимает, а не полное разрешение: кадр из потока — за пару секунд.
        let photo = try? await camera.capturePhoto(full: false)
        guard !Task.isCancelled, case .camera = state.stage else { return }
        if let photo {
            state.photo = photo
            await pass(.camera)
        } else {
            state.stage = .camera(failure: connected && link.isLinked.value ? .failed : .notConnected)
        }
    }

    /// Меняет шаг, только если на экране всё ещё шаг «Микрофон»: запоздалое событие прошлого шага новый не трогает.
    private func updateMicrophone(_ change: (CheckStage) -> CheckStage) {
        if case .microphone = state.stage { state.stage = change(state.stage) }
    }
}
