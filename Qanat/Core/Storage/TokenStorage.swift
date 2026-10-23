import Combine
import Foundation
import Security

struct AuthTokens: Equatable, Codable {
    let accessToken: String
    let refreshToken: String
}

/// Единственный источник истины о сессии: есть токены — пользователь авторизован.
protocol TokenStorage: AnyObject {
    var tokens: AnyPublisher<AuthTokens?, Never> { get }
    func current() -> AuthTokens?
    func save(_ tokens: AuthTokens)
    func clear()
}

/// Токены в Keychain: только на этом устройстве, после первой разблокировки (нужны и push в фоне).
final class KeychainTokenStorage: TokenStorage {
    private let service = "com.rating.qanatmobile.session"
    private let account = "tokens"
    private let subject: CurrentValueSubject<AuthTokens?, Never>
    private let lock = NSLock()

    init() {
        subject = CurrentValueSubject(nil)
        subject.value = read()
    }

    var tokens: AnyPublisher<AuthTokens?, Never> { subject.removeDuplicates().eraseToAnyPublisher() }

    func current() -> AuthTokens? {
        lock.withLock { subject.value }
    }

    func save(_ tokens: AuthTokens) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(tokens) else { return }
            SecItemDelete(baseQuery as CFDictionary)
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess { log.error("Токены не сохранились в Keychain: \(status)") }
        }
        subject.send(tokens)
    }

    func clear() {
        lock.withLock { _ = SecItemDelete(baseQuery as CFDictionary) }
        subject.send(nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read() -> AuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }
}

private let log = Log("TokenStorage")
