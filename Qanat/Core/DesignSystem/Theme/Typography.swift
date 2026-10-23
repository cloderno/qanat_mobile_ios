import SwiftUI

/// Стиль текста по макету: шрифт, размер, межстрочный интервал и трекинг, как TextStyle в Android-версии.
struct QTextStyle {
    enum Family { case onest, unbounded }

    var family: Family
    var weight: Font.Weight
    var size: CGFloat
    var lineHeight: CGFloat?
    var tracking: CGFloat = 0

    var fontName: String {
        switch (family, weight) {
        case (.unbounded, .medium): "Unbounded-Medium"
        case (.unbounded, _): "Unbounded-SemiBold"
        case (.onest, .medium): "Onest-Medium"
        case (.onest, .semibold): "Onest-SemiBold"
        case (.onest, .bold), (.onest, .heavy), (.onest, .black): "Onest-Bold"
        case (.onest, _): "Onest-Regular"
        }
    }

    /// Шрифт растёт вместе с крупным шрифтом системы, как sp на Android.
    var font: Font { .custom(fontName, size: size, relativeTo: .body) }

    var uiFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size))
    }

    func weight(_ weight: Font.Weight) -> QTextStyle {
        var copy = self
        copy.weight = weight
        return copy
    }

    func size(_ size: CGFloat, lineHeight: CGFloat? = nil) -> QTextStyle {
        var copy = self
        copy.size = size
        copy.lineHeight = lineHeight
        return copy
    }
}

/// Material-слоты — все на Onest (основной текст по макету).
enum Typography {
    static let displayLarge = QTextStyle(family: .onest, weight: .regular, size: 36, lineHeight: 44)
    static let displayMedium = QTextStyle(family: .onest, weight: .regular, size: 32, lineHeight: 40)
    static let displaySmall = QTextStyle(family: .onest, weight: .regular, size: 28, lineHeight: 36)

    static let headlineLarge = QTextStyle(family: .onest, weight: .semibold, size: 28, lineHeight: 36)
    static let headlineMedium = QTextStyle(family: .onest, weight: .semibold, size: 24, lineHeight: 32)
    static let headlineSmall = QTextStyle(family: .onest, weight: .semibold, size: 22, lineHeight: 28)

    static let titleLarge = QTextStyle(family: .onest, weight: .semibold, size: 20, lineHeight: 28)
    static let titleMedium = QTextStyle(family: .onest, weight: .semibold, size: 17, lineHeight: 24, tracking: 0.1)
    static let titleSmall = QTextStyle(family: .onest, weight: .semibold, size: 16, lineHeight: 22, tracking: 0.1)

    static let bodyLarge = QTextStyle(family: .onest, weight: .regular, size: 16, lineHeight: 24, tracking: 0.15)
    static let bodyMedium = QTextStyle(family: .onest, weight: .regular, size: 15, lineHeight: 22, tracking: 0.15)
    static let bodySmall = QTextStyle(family: .onest, weight: .regular, size: 13, lineHeight: 19, tracking: 0.2)

    static let labelLarge = QTextStyle(family: .onest, weight: .semibold, size: 14, lineHeight: 20, tracking: 0.1)
    static let labelMedium = QTextStyle(family: .onest, weight: .semibold, size: 12, lineHeight: 17, tracking: 0.3)
    static let labelSmall = QTextStyle(family: .onest, weight: .medium, size: 11, lineHeight: 16, tracking: 0.3)
}

/// Буква знака Qanat — в аватаре Каната и на иконке приложения.
let brandLetter = "Q"

/// Бренд — Unbounded, только для этих ролей.
enum BrandText {
    /// «Канат» в заголовке чата/композера.
    static let wordmark = QTextStyle(family: .unbounded, weight: .semibold, size: 16)
    /// Заголовок экрана — «Настройки», «Смарт-очки».
    static let screenTitle = QTextStyle(family: .unbounded, weight: .semibold, size: 18)
    /// Приветствие в новом чате — «Здравствуйте, …».
    static let greeting = QTextStyle(family: .unbounded, weight: .medium, size: 26, lineHeight: 31, tracking: -0.52)
    static let avatarLarge = QTextStyle(family: .unbounded, weight: .semibold, size: 22)
    static let avatarSmall = QTextStyle(family: .unbounded, weight: .semibold, size: 13)
    static let avatarTiny = QTextStyle(family: .unbounded, weight: .semibold, size: 11)
    /// Надпись «КАНАТ ГОВОРИТ» на экране голоса — капсом.
    static let voiceStatus = QTextStyle(family: .unbounded, weight: .medium, size: 13, tracking: 1)
}

private struct QTextStyleModifier: ViewModifier {
    let style: QTextStyle

    func body(content: Content) -> some View {
        let extra = style.lineHeight.map { max(0, $0 - style.uiFont.lineHeight * style.size / style.uiFont.pointSize) } ?? 0
        content
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(extra)
    }
}

extension View {
    func textStyle(_ style: QTextStyle) -> some View { modifier(QTextStyleModifier(style: style)) }
}
