import Foundation

private struct MeOutDto: Decodable {
    let email: String
    let displayName: String
    let roleTitle: String
    let organization: String?
    /// Относительная подписанная ссылка; nil — фото нет.
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case email, organization
        case displayName = "display_name"
        case roleTitle = "role_title"
        case avatarUrl = "avatar_url"
    }
}

/// Повторная регистрация того же токена просто обновляет его — отдельного device_id нет.
struct RegisterDeviceDto: Encodable {
    let token: String
    let platform: String
    let locale: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case token, platform, locale
        case appVersion = "app_version"
    }
}

struct RevokeDeviceDto: Encodable {
    let token: String
}

/// Корень сайта: ссылки на фото приходят от него, а не от /api/v1/.
func siteURL(_ relative: String, base: URL = AppConfig.baseURL) -> String? {
    URL(string: relative, relativeTo: URL(string: "/", relativeTo: base))?.absoluteString
}

final class SettingsRepositoryImpl: SettingsRepository {
    private let api: ApiClient
    private let deviceInfo: DeviceInfoProvider
    private let preferencesStorage: PreferencesStorage

    init(api: ApiClient, deviceInfo: DeviceInfoProvider, preferencesStorage: PreferencesStorage) {
        self.api = api
        self.deviceInfo = deviceInfo
        self.preferencesStorage = preferencesStorage
    }

    func me() async throws -> UserProfile {
        try await mapErrors {
            let dto: MeOutDto = try await api.get("auth/me")
            return UserProfile(
                email: dto.email,
                displayName: dto.displayName,
                roleTitle: dto.roleTitle,
                organization: dto.organization ?? "",
                avatarURL: dto.avatarUrl.flatMap { siteURL($0) }
            )
        }
    }

    func setPushEnabled(_ enabled: Bool) async throws {
        // Firebase не выдаёт токен в основном без сети — так и показываем.
        let token = await deviceInfo.pushToken()
        if token.isEmpty { throw SettingsError.network }
        try await mapErrors {
            if enabled {
                let _: OkDto = try await api.post(
                    "notifications/devices",
                    body: RegisterDeviceDto(token: token, platform: devicePlatform, locale: deviceInfo.locale(), appVersion: AppConfig.appVersion)
                )
            } else {
                let _: OkDto = try await api.post("notifications/devices/revoke", body: RevokeDeviceDto(token: token))
            }
        }
        preferencesStorage.update { $0.pushEnabled = enabled }
    }

    private func mapErrors<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch {
            throw error.isNetworkError ? SettingsError.network : SettingsError.server
        }
    }
}
