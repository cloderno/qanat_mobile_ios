import Foundation

/// Настройки сборки из Info.plist (их задают Config/*.xcconfig).
enum AppConfig {
    /// Адрес API, например https://qm.e-vko.kz/api/v1/ — всегда со слэшем на конце.
    static let baseURL: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "QanatBaseURL") as? String,
              let url = URL(string: raw.hasSuffix("/") ? raw : raw + "/")
        else { fatalError("QanatBaseURL не задан в Info.plist (Config/Shared.xcconfig)") }
        return url
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}

/// Страницы сайта, на которые ссылаются App Store и Wearables Developer Center: их должно быть видно из приложения.
enum SitePage: String {
    case privacy = "/mobile-privacy"
    case dataDeletion = "/data-deletion"
}

/// Адрес страницы на языке приложения: сайт понимает ?lang=ru|kk|en.
func sitePageURL(_ page: SitePage, language: AppLanguage = AppLanguage.effective, base: URL = AppConfig.baseURL) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.path = page.rawValue
    components.queryItems = [URLQueryItem(name: "lang", value: language.tag)]
    return components.url!
}
