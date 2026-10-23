import FirebaseMessaging
import Foundation

/// Данные об устройстве, которые сервер ждёт при входе (`device` в `/mobile/session`).
protocol DeviceInfoProvider {
    /// Push-токен Firebase. Пустая строка, если получить не удалось — вход всё равно не блокируем.
    func pushToken() async -> String

    /// Язык приложения, выбранный пользователем, иначе язык системы.
    func locale() -> String
}

/// Платформа устройства для сервера: push на iOS идут через FCM → APNs.
let devicePlatform = "ios"

final class FirebaseDeviceInfoProvider: DeviceInfoProvider {
    func pushToken() async -> String {
        // Без настроенного Firebase (нет GoogleService-Info.plist) или без APNs-токена FCM токен не выдаст —
        // логинимся и без него.
        guard PushSetup.isConfigured else { return "" }
        do {
            return try await Messaging.messaging().token()
        } catch {
            log.warning("Не удалось получить push-токен: \(error)")
            return ""
        }
    }

    func locale() -> String { AppLanguage.effective.tag }
}

private let log = Log("FirebaseDeviceInfo")
