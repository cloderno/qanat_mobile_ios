import Foundation

enum AuthError: Error, Equatable {
    case emptyCredentials
    case invalidCredentials
    case network
    case server
    /// Сервер отклонил сброс пароля и сам объяснил, почему (ссылка устарела или пароль слишком простой).
    case resetRejected(detail: String)
}

struct PasswordResetLink: Equatable {
    let valid: Bool
    let email: String?
}

protocol AuthRepository: AnyObject {
    /// Получает токены по логину и паролю и сохраняет сессию. Бросает [AuthError].
    func login(email: String, password: String) async throws

    /// Закрывает сессию: сервер забывает refresh и push-токен этого телефона, если до него удалось достучаться,
    /// а токены на телефоне стираются в любом случае. Не бросает.
    func logout() async

    /// Письмо со ссылкой на смену пароля. Сервер не сообщает, существует ли такой email.
    func requestPasswordReset(email: String) async throws

    /// Проверка ссылки из письма: valid = false — ссылка устарела.
    func checkPasswordResetLink(uid: String, token: String) async throws -> PasswordResetLink

    /// Новый пароль по ссылке из письма.
    func resetPassword(uid: String, token: String, newPassword: String) async throws
}

struct LoginUseCase {
    let repository: AuthRepository

    func callAsFunction(username: String, password: String) async throws {
        let login = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if login.isEmpty || password.isEmpty { throw AuthError.emptyCredentials }
        try await repository.login(email: login, password: password)
    }
}
