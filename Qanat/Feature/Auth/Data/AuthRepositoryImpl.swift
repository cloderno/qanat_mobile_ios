import Foundation

/// Без [device] вход проходит, а push на этот телефон не включаются.
struct LoginRequestDto: Encodable {
    let email: String
    let password: String
    let device: DeviceDto?
}

struct DeviceDto: Encodable {
    let token: String
    let platform: String
    let locale: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case token, platform, locale
        case appVersion = "app_version"
    }
}

/// [deviceToken] — тот же push-токен, что уходил в [DeviceDto.token]; пустой — push не отзываем.
private struct LogoutRequestDto: Encodable {
    let refresh: String
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case refresh
        case deviceToken = "device_token"
    }
}

private struct ForgotPasswordInDto: Encodable { let email: String }
private struct PasswordCheckDto: Decodable { let valid: Bool; let email: String? }
private struct ResetPasswordInDto: Encodable { let uid: String; let token: String; let password: String }

/// Тело ошибки сервера — JSON с полем "detail".
struct DetailDto: Decodable { let detail: String? }

final class AuthRepositoryImpl: AuthRepository {
    private let api: ApiClient
    private let tokenStorage: TokenStorage
    private let preferencesStorage: PreferencesStorage
    private let deviceInfo: DeviceInfoProvider

    init(api: ApiClient, tokenStorage: TokenStorage, preferencesStorage: PreferencesStorage, deviceInfo: DeviceInfoProvider) {
        self.api = api
        self.tokenStorage = tokenStorage
        self.preferencesStorage = preferencesStorage
        self.deviceInfo = deviceInfo
    }

    func login(email: String, password: String) async throws {
        // Push, выключенные в настройках, вход не должен включить снова.
        let device: DeviceDto? = preferencesStorage.current().pushEnabled
            ? DeviceDto(token: await deviceInfo.pushToken(), platform: devicePlatform, locale: deviceInfo.locale(), appVersion: AppConfig.appVersion)
            : nil
        let tokens: TokenResponseDto
        do {
            tokens = try await api.post("mobile/session", body: LoginRequestDto(email: email, password: password, device: device))
        } catch let error as HTTPError {
            throw [400, 401, 403].contains(error.code) ? AuthError.invalidCredentials : AuthError.server
        } catch is URLError {
            throw AuthError.network
        } catch {
            throw AuthError.server
        }
        tokenStorage.save(tokens.authTokens)
    }

    func logout() async {
        defer { tokenStorage.clear() }
        guard let refresh = tokenStorage.current()?.refreshToken else { return }
        let deviceToken = await deviceInfo.pushToken()
        // Без сети выход не должен зависать: на телефоне сессия закроется и без ответа сервера.
        let sent = await withTimeout(seconds: 5) {
            try await self.api.send("POST", "mobile/session/logout", body: LogoutRequestDto(refresh: refresh, deviceToken: deviceToken))
        }
        if sent == nil { log.warning("Сервер не принял выход или не ответил за 5 с") }
    }

    func requestPasswordReset(email: String) async throws {
        do {
            try await api.send("POST", "auth/password/forgot", body: ForgotPasswordInDto(email: email))
        } catch {
            throw error.isNetworkError ? AuthError.network : AuthError.server
        }
    }

    func checkPasswordResetLink(uid: String, token: String) async throws -> PasswordResetLink {
        do {
            let result: PasswordCheckDto = try await api.get(
                "auth/password/check",
                query: [URLQueryItem(name: "uid", value: uid), URLQueryItem(name: "token", value: token)]
            )
            return PasswordResetLink(valid: result.valid, email: result.email)
        } catch {
            throw error.isNetworkError ? AuthError.network : AuthError.server
        }
    }

    func resetPassword(uid: String, token: String, newPassword: String) async throws {
        do {
            try await api.send("POST", "auth/password/reset", body: ResetPasswordInDto(uid: uid, token: token, password: newPassword))
        } catch let error as HTTPError where error.code == 400 {
            let detail = (try? JSONDecoder().decode(DetailDto.self, from: error.body))?.detail
            throw AuthError.resetRejected(detail: detail ?? "HTTP 400")
        } catch {
            throw error.isNetworkError ? AuthError.network : AuthError.server
        }
    }
}

private let log = Log("AuthRepository")
