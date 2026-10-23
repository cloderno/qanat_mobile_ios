import Combine
import Foundation
import UserNotifications

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var isLoading = true
    private(set) var profile: UserProfile?
    private(set) var isGlassesRegistered = false
    /// Очки, как их видит Meta SDK; nil — очки ещё не известны.
    private(set) var glassesInfo: GlassesDeviceInfo?
    private(set) var language: AppLanguage = AppLanguage.effective
    private(set) var errorKey: String?
    private(set) var preferences = AppPreferences()
    /// Куда переключают push, пока сервер не ответил; nil — ничего не переключают.
    private(set) var pendingPush: Bool?
    var pushErrorKey: String?
    /// Запрет уведомлений в системе прячет push, что бы ни выбрали здесь.
    private(set) var notificationsAllowed = true

    var glassesStatus: GlassesStatus { Qanat.glassesStatus(registered: isGlassesRegistered, info: glassesInfo) }

    private let repository: SettingsRepository
    private let preferencesStorage: PreferencesStorage
    private var subscriptions = Set<AnyCancellable>()

    init(repository: SettingsRepository, preferencesStorage: PreferencesStorage, glasses: GlassesControls) {
        self.repository = repository
        self.preferencesStorage = preferencesStorage
        preferences = preferencesStorage.current()
        glasses.isRegistered.receive(on: DispatchQueue.main).sink { [weak self] in self?.isGlassesRegistered = $0 }.store(in: &subscriptions)
        glasses.deviceInfo.receive(on: DispatchQueue.main).sink { [weak self] in self?.glassesInfo = $0 }.store(in: &subscriptions)
        preferencesStorage.preferences.receive(on: DispatchQueue.main).sink { [weak self] in self?.preferences = $0 }.store(in: &subscriptions)
    }

    /// Экран зовёт при каждом входе: в «Профиле» могли сменить ФИО и фото. Уже показанный профиль не прячем за загрузкой.
    func load() async {
        isLoading = profile == nil
        errorKey = nil
        do {
            profile = try await repository.me()
        } catch {
            errorKey = (error as? SettingsError) == .network ? "settings_error_network" : "settings_error_server"
        }
        isLoading = false
    }

    func refreshNotificationsAllowed() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus != .denied
    }

    func selectLanguage(_ language: AppLanguage) {
        AppLanguage.set(language)
        self.language = language
    }

    func setVoiceReply(_ enabled: Bool) { preferencesStorage.update { $0.voiceReplyToNotes = enabled } }
    func setSpeakAnswers(_ enabled: Bool) { preferencesStorage.update { $0.speakAnswers = enabled } }
    func setStartEndSounds(_ enabled: Bool) { preferencesStorage.update { $0.startEndSounds = enabled } }
    /// То же переключение, что и на экране «Смарт-очки» — то же поле настроек, просто доступно и тут.
    func setGlassesVoiceReplies(_ enabled: Bool) { preferencesStorage.update { $0.glassesVoiceReplies = enabled } }
    func setGlassesSaveToGallery(_ enabled: Bool) { preferencesStorage.update { $0.glassesSaveToGallery = enabled } }

    func togglePush(_ enabled: Bool) {
        guard pendingPush == nil else { return }
        pendingPush = enabled
        pushErrorKey = nil
        Task {
            defer { pendingPush = nil }
            do {
                if enabled { await PushSetup.requestAuthorization() }
                try await repository.setPushEnabled(enabled)
            } catch {
                pushErrorKey = (error as? SettingsError) == .network ? "settings_push_error_network" : "settings_push_error_server"
            }
        }
    }
}
