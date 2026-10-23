import Foundation

/// Ответ сервера с парой токенов — общий для логина и обновления.
struct TokenResponseDto: Decodable {
    let access: String
    let refresh: String

    var authTokens: AuthTokens { AuthTokens(accessToken: access, refreshToken: refresh) }
}

struct RefreshTokenRequestDto: Encodable {
    let refresh: String
}

/// Обновляет access-токен через refresh. Голосовой WebSocket сообщает о протухшем токене кодом закрытия и зовёт
/// [refresh] сам. Если сервер отверг refresh-токен — очищает сессию, что возвращает пользователя на логин.
/// Сетевые ошибки при обновлении сессию не трогают.
actor TokenAuthenticator {
    private let tokenStorage: TokenStorage
    private let baseURL: URL
    private let session: URLSession
    private var inFlight: Task<AuthTokens?, Never>?

    init(tokenStorage: TokenStorage, baseURL: URL, session: URLSession = .shared) {
        self.tokenStorage = tokenStorage
        self.baseURL = baseURL
        self.session = session
    }

    /// Обновляет токены после того, как сервер отверг [failedAccessToken]. nil — сессии нет или refresh не удался.
    func refresh(failedAccessToken: String) async -> AuthTokens? {
        // Параллельные запросы с тем же протухшим токеном ждут одно обновление.
        if let inFlight { return await inFlight.value }
        guard let current = tokenStorage.current() else { return nil }
        // Пока ждали, токен уже обновил другой запрос.
        if current.accessToken != failedAccessToken { return current }
        let task = Task { await freshTokens(current) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func freshTokens(_ current: AuthTokens) async -> AuthTokens? {
        // Отдельный запрос без авторизации, иначе обновление токена зациклилось бы на самом себе.
        var request = URLRequest(url: URL(string: "mobile/session/refresh", relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshTokenRequestDto(refresh: current.refreshToken))
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                if (400...403).contains(code) { tokenStorage.clear() } else { log.warning("Refresh failed: HTTP \(code)") }
                return nil
            }
            let tokens = try JSONDecoder().decode(TokenResponseDto.self, from: data).authTokens
            tokenStorage.save(tokens)
            return tokens
        } catch {
            log.warning("Refresh failed: \(error)")
            return nil
        }
    }
}

private let log = Log("TokenAuthenticator")
