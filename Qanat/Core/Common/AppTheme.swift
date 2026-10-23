import SwiftUI

/// Тема приложения: системная или выбранная явно. Выбор хранится на телефоне и применяется к корню приложения.
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "SYSTEM"
    case light = "LIGHT"
    case dark = "DARK"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@Observable
final class ThemeSettings {
    static let shared = ThemeSettings()
    private static let key = "theme"

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    private init() {
        theme = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.init(rawValue:)) ?? .system
    }
}
