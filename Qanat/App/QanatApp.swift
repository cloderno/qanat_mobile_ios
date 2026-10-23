import SwiftUI
import UIKit

@main
struct QanatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            AppRoot(container: delegate.container)
        }
    }
}

/// Запуск приложения: Meta Wearables SDK, push и зависимости — до первого экрана (на Android — QanatMobileApp).
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private(set) lazy var container = AppContainer()

    @MainActor
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        GlassesSdk.configure()
        PushSetup.shared.start(
            tokenStorage: container.tokenStorage,
            preferencesStorage: container.preferencesStorage,
            api: container.api,
            deviceInfo: container.deviceInfo,
            chatPushEvents: container.chatPushEvents
        )
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushSetup.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log("Push").warning("APNs не выдал токен: \(error)")
    }
}
