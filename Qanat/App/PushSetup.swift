import Combine
import FirebaseCore
import FirebaseMessaging
import UIKit
import UserNotifications

/// Push через Firebase Messaging (FCM → APNs) и системные уведомления приложения. На Android это
/// QanatMessagingService и каналы уведомлений.
///
/// Firebase настраивается, только если в сборке есть GoogleService-Info.plist: без него приложение работает, но push нет.
final class PushSetup: NSObject, UNUserNotificationCenterDelegate, MessagingDelegate {
    static let shared = PushSetup()

    /// Firebase настроен — FCM может выдать токен.
    private(set) static var isConfigured = false

    /// Чат из push, по которому нажали; AppRoot открывает его и сбрасывает в nil.
    let openedChatId = CurrentValueSubject<String?, Never>(nil)
    /// Кнопка (или само уведомление) о сбое команды с очков — открывает экран голоса.
    let voiceNoticeAction = CurrentValueSubject<VoiceNoticeAction?, Never>(nil)

    private var tokenStorage: TokenStorage?
    private var preferencesStorage: PreferencesStorage?
    private var api: ApiClient?
    private var deviceInfo: DeviceInfoProvider?
    private var chatPushEvents: ChatPushEvents?

    /// Вызывается при запуске приложения, до первого push.
    func start(tokenStorage: TokenStorage, preferencesStorage: PreferencesStorage, api: ApiClient, deviceInfo: DeviceInfoProvider, chatPushEvents: ChatPushEvents) {
        self.tokenStorage = tokenStorage
        self.preferencesStorage = preferencesStorage
        self.api = api
        self.deviceInfo = deviceInfo
        self.chatPushEvents = chatPushEvents

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(VoiceFailureNotification.registerCategories()))

        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            log.warning("GoogleService-Info.plist нет в сборке — push выключены")
            return
        }
        FirebaseApp.configure()
        Messaging.messaging().delegate = self
        Self.isConfigured = true
        // APNs-токен нужен FCM всегда; разрешение показывать уведомления спрашиваем отдельно ([requestAuthorization]).
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Разрешение показывать уведомления. Спрашиваем, когда пользователь включает push в настройках или после входа.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func didRegister(deviceToken: Data) {
        guard Self.isConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
    }

    // MARK: MessagingDelegate

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, let tokenStorage, let preferencesStorage, let api, let deviceInfo else { return }
        // Токен мог обновиться до входа (переустановка) — регистрируем только вошедшего пользователя,
        // вход сам отправит текущий токен в /mobile/session.
        guard tokenStorage.current() != nil else { return }
        // Новый токен не должен тайком включить push, выключенные в настройках.
        guard preferencesStorage.current().pushEnabled else { return }
        Task {
            do {
                let _: OkDto = try await api.post(
                    "notifications/devices",
                    body: RegisterDeviceDto(token: fcmToken, platform: devicePlatform, locale: deviceInfo.locale(), appVersion: AppConfig.appVersion)
                )
            } catch {
                log.warning("Не удалось перерегистрировать push-токен: \(error)")
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Push, пока приложение на переднем плане: видимый экран чата сразу подтянет ответ. Уведомление не показываем,
    /// только если ответ действительно появился в открытом чате.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let chatId = pushChatId(userInfo), let chatPushEvents, await chatPushEvents.deliver(chatId: chatId) { return [] }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let link = userInfo["open_url"] as? String, let url = URL(string: link) {
            await UIApplication.shared.open(url)
            return
        }
        if response.notification.request.content.categoryIdentifier.hasPrefix(VoiceFailureNotification.category) {
            let action = VoiceNoticeAction(rawValue: response.actionIdentifier) ?? .open
            await MainActor.run { voiceNoticeAction.send(action) }
            return
        }
        // Пока открываем конкретно только ответ агента; остальные push просто открывают приложение.
        if let chatId = pushChatId(userInfo) {
            await MainActor.run { openedChatId.send(chatId) }
        }
    }
}

private let log = Log("Push")
