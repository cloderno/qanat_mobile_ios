import Combine
import Foundation

/// Что открыть в Meta AI.
enum RegistrationCommand: Equatable { case register, unregister }

enum RegistrationFailure: Equatable {
    /// SDK сообщил об ошибке.
    case sdkError
    /// Вернулись из Meta AI, а Qanat так и не подключён (или старое подключение так и не снято).
    case notConfirmed
    /// Ответа от Meta AI не дождались.
    case timeout
    /// Meta AI не открыть.
    case notOpened
}

/// Попытка подключить Qanat в Meta AI. Meta AI не сообщает об отказе явно, поэтому неудачей считаем и молчание:
/// вернулись в Qanat, а подключения нет. Время здесь не считается — таймеры ставит ViewModel и сообщает событиями.
enum RegistrationAttempt: Equatable {
    case idle
    /// Ждём ответа Meta AI. [phase] — что сейчас просили; [leftApp] — пользователь ушёл из Qanat, [returned] — и вернулся.
    /// [sdkBusy] — SDK заканчивает подключение или отвязку. [unregisterTried] — старое подключение уже пробовали снять.
    case waiting(phase: RegistrationCommand, leftApp: Bool, returned: Bool, sdkBusy: Bool, unregisterTried: Bool)
    case failed(RegistrationFailure)

    /// Вернулись из Meta AI, а SDK ничем не занят: идёт короткое ожидание, потом — неудача.
    var awaitsConfirmation: Bool {
        if case .waiting(_, _, let returned, let sdkBusy, _) = self { return returned && !sdkBusy }
        return false
    }

    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }

    static func waitingFor(_ phase: RegistrationCommand, unregisterTried: Bool = false) -> RegistrationAttempt {
        .waiting(phase: phase, leftApp: false, returned: false, sdkBusy: false, unregisterTried: unregisterTried)
    }
}

enum RegistrationEvent: Equatable {
    /// Пользователь начал подключение или нажал «Попробовать снова».
    case started
    case sdkState(GlassesRegistrationState)
    case sdkError(GlassesRegistrationError)
    case leftApp
    case returned
    case notOpened
    /// Прошло короткое ожидание после возврата в Qanat.
    case graceExpired
    /// Прошло общее ожидание ответа Meta AI.
    case timedOut
    /// Пользователь закрыл экран помощи или ушёл с подключения.
    case dismissed
}

/// Новое состояние попытки и, если нужно, что открыть в Meta AI прямо сейчас.
struct RegistrationTransition: Equatable {
    let attempt: RegistrationAttempt
    var command: RegistrationCommand?
}

extension RegistrationAttempt {
    func on(_ event: RegistrationEvent) -> RegistrationTransition {
        if event == .started {
            if case .waiting(let phase, _, _, let busy, let tried) = self {
                // Meta AI так и не открылся (или пользователь вернулся ни с чем) — открываем его снова тем же шагом.
                return RegistrationTransition(attempt: .waiting(phase: phase, leftApp: false, returned: false, sdkBusy: busy, unregisterTried: tried), command: phase)
            }
            return RegistrationTransition(attempt: .waitingFor(.register), command: .register)
        }
        // Подключение могло завершиться и после того, как мы сочли попытку неудачной.
        if event == .sdkState(.registered) || event == .dismissed { return RegistrationTransition(attempt: .idle) }
        guard case .waiting(let phase, let leftApp, let returned, let sdkBusy, let tried) = self else {
            return RegistrationTransition(attempt: self)
        }
        func with(left: Bool? = nil, back: Bool? = nil, busy: Bool? = nil) -> RegistrationTransition {
            RegistrationTransition(attempt: .waiting(phase: phase, leftApp: left ?? leftApp, returned: back ?? returned, sdkBusy: busy ?? sdkBusy, unregisterTried: tried))
        }
        let registerAgain = RegistrationTransition(attempt: .waitingFor(.register, unregisterTried: true), command: .register)
        switch event {
        case .sdkState(let state):
            if state == .registering || state == .unregistering { return with(busy: true) }
            // Отвязка старого подключения закончилась — подключаем заново, где бы ни был пользователь.
            return phase == .unregister && sdkBusy ? registerAgain : with(busy: false)
        case .sdkError(let error):
            // Meta AI помнит Qanat от прошлой установки: один раз снимаем старое подключение и подключаем снова.
            if error == .alreadyRegistered && !tried {
                return RegistrationTransition(attempt: .waitingFor(.unregister, unregisterTried: true), command: .unregister)
            }
            if error == .alreadyUnregistered && phase == .unregister { return registerAgain }
            return RegistrationTransition(attempt: .failed(.sdkError))
        case .leftApp:
            return with(left: true, back: false)
        case .returned:
            return leftApp ? with(back: true) : RegistrationTransition(attempt: self)
        case .notOpened:
            return RegistrationTransition(attempt: .failed(.notOpened))
        case .graceExpired:
            return awaitsConfirmation ? RegistrationTransition(attempt: .failed(.notConfirmed)) : RegistrationTransition(attempt: self)
        case .timedOut:
            return RegistrationTransition(attempt: .failed(.timeout))
        default:
            return RegistrationTransition(attempt: self)
        }
    }
}

/// Подключение Qanat в Meta AI и распознавание неудачи — см. [RegistrationAttempt].
@MainActor
@Observable
final class GlassesRegistrationViewModel {
    private(set) var attempt: RegistrationAttempt = .idle

    private let controls: MetaGlassesControls
    private var timeout: Task<Void, Never>?
    private var grace: Task<Void, Never>?
    private var sdkState: GlassesRegistrationState?
    private var sdkError: GlassesRegistrationError?
    private var subscriptions = Set<AnyCancellable>()

    /// Столько ждём ответа Meta AI, даже если пользователь так и не вернулся в Qanat.
    static let responseTimeout: Double = 60
    /// После возврата в Qanat SDK узнаёт о подключении не мгновенно.
    static let returnGrace: Double = 5

    init(controls: MetaGlassesControls) {
        self.controls = controls
        controls.state.receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.sdkState = state
            self?.reduce(.sdkState(state))
        }.store(in: &subscriptions)
        controls.errors.receive(on: DispatchQueue.main).sink { [weak self] error in
            self?.sdkError = error
            self?.reduce(.sdkError(error))
        }.store(in: &subscriptions)
    }

    func connect() { start() }
    func retry() { start() }
    func helpClosed() { reduce(.dismissed) }
    func leftApp() { reduce(.leftApp) }
    func returned() { reduce(.returned) }

    private func start() {
        if !attempt.isWaiting { sdkError = nil }
        reduce(.started)
        // SDK мог уже заканчивать прошлое подключение — новая попытка должна это знать.
        if let sdkState { reduce(.sdkState(sdkState)) }
    }

    private func reduce(_ event: RegistrationEvent) {
        let before = attempt
        let transition = before.on(event)
        attempt = transition.attempt
        if case .failed(let cause) = attempt, !(before == attempt) {
            log.warning("Подключение не удалось: \(cause), SDK: \(String(describing: sdkState)), последняя ошибка SDK: \(String(describing: sdkError)), событие \(event)")
        } else if transition.command == .unregister {
            log.warning("Meta AI помнит старое подключение Qanat — снимаем его и подключаем заново")
        }
        if let command = transition.command {
            Task {
                switch command {
                case .register: await controls.startRegistration()
                case .unregister: await controls.startUnregistration()
                }
            }
        }
        if !attempt.isWaiting {
            cancelTimers()
        } else if transition.command != nil {
            // Каждый новый переход в Meta AI — новое ожидание его ответа.
            cancelTimers()
            timeout = Task {
                try? await Task.sleep(for: .seconds(Self.responseTimeout))
                if !Task.isCancelled { reduce(.timedOut) }
            }
        } else if !attempt.awaitsConfirmation {
            // Пока SDK заканчивает подключение или отвязку, короткое ожидание не идёт.
            grace?.cancel()
        } else if !before.awaitsConfirmation {
            grace = Task {
                try? await Task.sleep(for: .seconds(Self.returnGrace))
                if !Task.isCancelled { reduce(.graceExpired) }
            }
        }
    }

    private func cancelTimers() {
        timeout?.cancel()
        grace?.cancel()
    }
}

private let log = Log("GlassesRegistration")
