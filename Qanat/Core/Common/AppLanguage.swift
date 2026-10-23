import Foundation

/// Язык приложения независимо от системного — три поддерживаемых варианта.
enum AppLanguage: String, CaseIterable, Identifiable {
    case russian = "ru"
    case kazakh = "kk"
    case english = "en"

    var id: String { rawValue }
    var tag: String { rawValue }

    private static let key = "app_language"

    /// Текущий выбранный язык, или nil — используется системный.
    static var current: AppLanguage? {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:))
    }

    static func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.tag, forKey: key)
        LanguageSettings.shared.language = language
    }

    /// Выбранный язык, иначе системный (если он из поддерживаемых), иначе русский.
    static var effective: AppLanguage {
        current ?? Locale.preferredLanguages.lazy
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .compactMap(AppLanguage.init(rawValue:))
            .first ?? .russian
    }

    var locale: Locale { Locale(identifier: tag) }

    /// Бандл .lproj этого языка: строки берём из него, а не из системного выбора.
    var bundle: Bundle {
        Bundle.main.path(forResource: tag, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

/// Наблюдаемый язык: корень приложения перерисовывается при его смене (на Android — пересоздание Activity).
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()

    var language: AppLanguage = AppLanguage.effective

    private init() {}
}
