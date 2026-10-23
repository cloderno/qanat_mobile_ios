import Foundation

/// Ответ сервера с кодом не 2xx. [body] — тело ответа: по нему разбирают `detail` и коды ошибок.
struct HTTPError: Error {
    let code: Int
    let body: Data
}

/// Сервер ответил 2xx, но не тем, что мы ждали.
struct UnexpectedResponseError: Error {
    let underlying: Error
}

/// HTTP-клиент API: добавляет access-токен, на 401 обновляет его через refresh и повторяет запрос один раз.
/// Аналог OkHttp + AuthInterceptor + TokenAuthenticator из Android-версии.
final class ApiClient {
    let baseURL: URL
    let session: URLSession
    private let tokenStorage: TokenStorage
    private let authenticator: TokenAuthenticator

    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    init(baseURL: URL, tokenStorage: TokenStorage, authenticator: TokenAuthenticator, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenStorage = tokenStorage
        self.authenticator = authenticator
        self.session = session
    }

    /// Адрес [path] относительно базового (без ведущего слэша: "mobile/chats").
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = URL(string: path, relativeTo: baseURL)!.absoluteURL
        guard !query.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + query
        return components.url!
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        return request
    }

    // MARK: JSON

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(try await data(request("GET", path, query: query)))
    }

    func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try decode(try await data(jsonRequest("POST", path, body: body)))
    }

    func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try decode(try await data(jsonRequest("PATCH", path, body: body)))
    }

    func put<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try decode(try await data(jsonRequest("PUT", path, body: body)))
    }

    /// Запрос без тела ответа (204 или тело, которое не нужно).
    func send(_ method: String, _ path: String, body: (any Encodable)? = nil, query: [URLQueryItem] = []) async throws {
        var request = request(method, path, query: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(AnyEncodable(body))
        }
        _ = try await data(request)
    }

    func jsonRequest(_ method: String, _ path: String, body: some Encodable) throws -> URLRequest {
        var request = request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw UnexpectedResponseError(underlying: error)
        }
    }

    // MARK: Транспорт

    /// Тело ответа 2xx; иначе [HTTPError]. Сетевые сбои — URLError.
    func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await authorized(request) { try await self.session.data(for: $0) }
        try Self.check(response, body: data)
        return data
    }

    /// Поток ответа по байтам — для потоковых ответов агента.
    func bytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await authorized(request) { try await self.session.bytes(for: $0) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw HTTPError(code: http.statusCode, body: body)
        }
        return (bytes, http)
    }

    /// Загрузка файла во временный файл — для документов и медиа.
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (file, response) = try await authorized(request) { try await self.session.download(for: $0) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: file)) ?? Data()
            throw HTTPError(code: http.statusCode, body: body)
        }
        return (file, http)
    }

    /// Выполняет [perform] с токеном; на 401 обновляет токен и повторяет один раз.
    private func authorized<T>(
        _ request: URLRequest,
        perform: (URLRequest) async throws -> (T, URLResponse)
    ) async throws -> (T, URLResponse) {
        var request = request
        let token = tokenStorage.current()?.accessToken
        if request.value(forHTTPHeaderField: "Authorization") == nil, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let first = try await perform(request)
        guard (first.1 as? HTTPURLResponse)?.statusCode == 401, let token,
              let fresh = await authenticator.refresh(failedAccessToken: token)
        else { return first }
        request.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(code: http.statusCode, body: body) }
    }
}

/// Обёртка, чтобы закодировать `any Encodable`.
struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Пустой ответ `{}` или `{"ok": true}`.
struct OkDto: Decodable {
    let ok: Bool?
}

extension Error {
    /// Нет сети, таймаут, сервер недоступен — то, что Android-версия ловит как IOException.
    var isNetworkError: Bool { self is URLError }

    var httpCode: Int? { (self as? HTTPError)?.code }
}
