import Combine
import Foundation

/// Выбор пользователя, который хранится только на этом телефоне и переживает выход из аккаунта.
struct AppPreferences: Equatable, Codable {
    /// Только голосовые из чата на телефоне: у голосовых с очков свой выбор — [glassesVoiceReplies].
    var voiceReplyToNotes = false
    var speakAnswers = false
    var glassesVoiceReplies = true
    var glassesVision = true
    /// Каждый снимок и видео с очков — ещё и в альбом «Qanat» галереи телефона.
    var glassesSaveToGallery = false
    /// Сервер о выборе не знает: выключенные push — это отозванный на сервере телефон.
    var pushEnabled = true
    /// Короткие сигналы, когда начинается и кончается голосовое или разговор с Канатом.
    var startEndSounds = true
}

protocol PreferencesStorage: AnyObject {
    var preferences: AnyPublisher<AppPreferences, Never> { get }
    func current() -> AppPreferences
    func update(_ transform: (inout AppPreferences) -> Void)
}

final class UserDefaultsPreferencesStorage: PreferencesStorage {
    private let defaults: UserDefaults
    private let key = "preferences"
    private let subject: CurrentValueSubject<AppPreferences, Never>
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Битые данные — как на Android ReplaceFileCorruptionHandler: начинаем с умолчаний.
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) }
        subject = CurrentValueSubject(stored ?? AppPreferences())
    }

    var preferences: AnyPublisher<AppPreferences, Never> { subject.removeDuplicates().eraseToAnyPublisher() }

    func current() -> AppPreferences { lock.withLock { subject.value } }

    func update(_ transform: (inout AppPreferences) -> Void) {
        let updated: AppPreferences = lock.withLock {
            var value = subject.value
            transform(&value)
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
            return value
        }
        subject.send(updated)
    }
}
