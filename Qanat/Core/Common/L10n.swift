import Foundation

/// Строки на языке приложения ([AppLanguage]), а не системы. Ключи — те же, что в Android (`login_title`).
enum L {
    static func t(_ key: String) -> String {
        LanguageSettings.shared.language.bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Строка с подстановкой: `%1$@`, `%d` — как в Android-ресурсе.
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: LanguageSettings.shared.language.locale, arguments: args)
    }

    /// Plurals из Localizable.stringsdict: число выбирает форму, остальные аргументы подставляются как есть.
    static func plural(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: LanguageSettings.shared.language.locale, arguments: args)
    }
}
