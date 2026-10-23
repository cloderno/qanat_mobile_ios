import Foundation

enum LoginStatus: Equatable {
    case idle
    case submitting
    case error(messageKey: String)
}

/// После успешного входа сессия появляется в TokenStorage, и приложение само переключает экран.
@MainActor
@Observable
final class LoginViewModel {
    var email = "" { didSet { if email != oldValue { status = .idle } } }
    var password = "" { didSet { if password != oldValue { status = .idle } } }
    private(set) var status: LoginStatus = .idle

    var canSubmit: Bool { status != .submitting && !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }

    private let login: LoginUseCase

    init(login: LoginUseCase) {
        self.login = login
    }

    func submit() {
        guard canSubmit else { return }
        status = .submitting
        Task {
            do {
                try await login(username: email, password: password)
                status = .idle
            } catch {
                status = .error(messageKey: Self.messageKey(error))
            }
        }
    }

    private static func messageKey(_ error: Error) -> String {
        switch error as? AuthError {
        case .emptyCredentials: "login_error_empty"
        case .invalidCredentials: "login_error_invalid_credentials"
        case .network: "login_error_network"
        default: "login_error_server"
        }
    }
}

enum ForgotPasswordStatus: Equatable {
    case idle
    case submitting
    /// Письмо отправлено; сервер не говорит, существует ли такой email — текст одинаковый в любом случае.
    case sent
    case error(messageKey: String)
}

@MainActor
@Observable
final class ForgotPasswordViewModel {
    var email = "" { didSet { if email != oldValue, status != .sent { status = .idle } } }
    private(set) var status: ForgotPasswordStatus = .idle

    var canSubmit: Bool { status != .submitting && !email.trimmingCharacters(in: .whitespaces).isEmpty }

    private let repository: AuthRepository

    init(repository: AuthRepository) {
        self.repository = repository
    }

    func submit() {
        guard canSubmit else { return }
        status = .submitting
        Task {
            do {
                try await repository.requestPasswordReset(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
                status = .sent
            } catch {
                status = .error(messageKey: (error as? AuthError) == .network ? "login_error_network" : "login_error_server")
            }
        }
    }
}

enum ResetLinkStatus: Equatable {
    case checking
    case valid(email: String?)
    case invalid
    /// Ссылку не удалось проверить (сеть, сервер) — сама она может быть ещё действительна, проверку можно повторить.
    case error(messageKey: String)
    case done
}

/// Текст ошибки сброса пароля: либо наш, по ключу строки, либо от сервера — буквально то, что он объяснил.
enum ResetPasswordError: Equatable {
    case localized(key: String)
    case fromServer(String)

    var text: String {
        switch self {
        case .localized(let key): L.t(key)
        case .fromServer(let text): text
        }
    }
}

/// uid/token приходят из ссылки письма.
@MainActor
@Observable
final class ResetPasswordViewModel {
    static let minPasswordLength = 8

    private(set) var status: ResetLinkStatus = .checking
    var password = "" { didSet { error = nil } }
    var confirmPassword = "" { didSet { error = nil } }
    private(set) var submitting = false
    private(set) var error: ResetPasswordError?

    var passwordsMatch: Bool { password == confirmPassword }
    var canSubmit: Bool { !submitting && password.count >= Self.minPasswordLength && passwordsMatch }

    /// Ошибка у полей: короткий пароль или пароли не совпадают.
    var fieldErrorKey: String? {
        if !password.isEmpty && password.count < Self.minPasswordLength { return "reset_password_too_short" }
        if !confirmPassword.isEmpty && !passwordsMatch { return "reset_password_mismatch" }
        return nil
    }

    private let repository: AuthRepository
    private let uid: String
    private let token: String

    init(repository: AuthRepository, uid: String, token: String) {
        self.repository = repository
        self.uid = uid
        self.token = token
        checkLink()
    }

    func retryCheck() {
        status = .checking
        checkLink()
    }

    private func checkLink() {
        Task {
            do {
                let link = try await repository.checkPasswordResetLink(uid: uid, token: token)
                status = link.valid ? .valid(email: link.email) : .invalid
            } catch {
                status = .error(messageKey: (error as? AuthError) == .network ? "reset_password_error_network" : "login_error_server")
            }
        }
    }

    func submit() {
        guard canSubmit else { return }
        submitting = true
        error = nil
        Task {
            do {
                try await repository.resetPassword(uid: uid, token: token, newPassword: password)
                submitting = false
                status = .done
            } catch {
                submitting = false
                self.error = switch error as? AuthError {
                case .resetRejected(let detail): .fromServer(detail)
                case .network: .localized(key: "reset_password_error_network")
                default: .localized(key: "login_error_server")
                }
            }
        }
    }
}
