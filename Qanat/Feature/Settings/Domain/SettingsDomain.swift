import Foundation

enum SettingsError: Error {
    case network
    case server
}

/// Профиль пользователя, вошедшего в приложение.
struct UserProfile: Equatable {
    let email: String
    let displayName: String
    let roleTitle: String
    let organization: String
    /// Полный адрес фото; nil — фото нет, показываем инициалы.
    var avatarURL: String?
}

/// Профиль пользователя и push на этом телефоне. Бросает [SettingsError].
protocol SettingsRepository: AnyObject {
    func me() async throws -> UserProfile

    /// Регистрирует телефон для push или отзывает его; выбор запоминается, только когда сервер его принял.
    func setPushEnabled(_ enabled: Bool) async throws
}
