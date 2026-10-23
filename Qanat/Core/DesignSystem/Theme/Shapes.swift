import SwiftUI

/// По макету: пункты списка/подсказки — 12–14pt, карточки — 20pt.
enum Radius {
    static let extraSmall: CGFloat = 10
    static let small: CGFloat = 12
    static let medium: CGFloat = 20
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 28
    /// Подсказки-кнопки в композере нового чата.
    static let suggestion: CGFloat = 14
    /// Поля ввода и основная кнопка на экранах входа/пароля.
    static let authField: CGFloat = 16
    static let authButton: CGFloat = 18
}

/// Пузырь вопроса — «хвостик» снизу-справа, как в макете.
let chatBubbleShape = UnevenRoundedRectangle(
    topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22, style: .continuous
)

/// Шкала отступов (шаг 4pt) — чтобы padding/spacing не изобретались на глаз.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}
