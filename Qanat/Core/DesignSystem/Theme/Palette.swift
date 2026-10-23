import SwiftUI

extension Color {
    /// Цвет из 0xRRGGBB, как в Android-палитре (Color.kt).
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Палитра по макету: тёплый крем в светлой теме, тёмно-графитовая в тёмной. Слоты — те же, что у Material
/// ColorScheme в Android-версии, чтобы экраны переносились один к одному.
struct Palette {
    var primary: Color
    var onPrimary: Color
    var primaryContainer: Color
    var onPrimaryContainer: Color
    var secondary: Color
    var secondaryContainer: Color
    var onSecondaryContainer: Color
    var tertiary: Color
    var tertiaryContainer: Color
    var onTertiaryContainer: Color
    var background: Color
    var onBackground: Color
    var surface: Color
    var onSurface: Color
    var surfaceVariant: Color
    var onSurfaceVariant: Color
    var surfaceContainerLow: Color
    var surfaceContainer: Color
    var surfaceContainerHigh: Color
    var surfaceContainerHighest: Color
    var outline: Color
    var outlineVariant: Color
    var error: Color
    var onError: Color
    var errorContainer: Color
    var onErrorContainer: Color
    var inverseSurface: Color
    var inverseOnSurface: Color
    var tones: ToneColors
    var isDark: Bool
}

/// Цвета для KPI-тайлов и похожих акцентов тона — отдельно от основной палитры.
struct ToneColors {
    var positiveContainer: Color
    var positive: Color
    var negativeContainer: Color
    var negative: Color
    var warningContainer: Color
    var warning: Color
    /// Точка «подключено» — тил, а не зелёный KPI-тон.
    var connected: Color
    /// Подложка сегментированного переключателя и выбранный сегмент.
    var segmentTrack: Color
    var segmentSelected: Color
    /// Текстовое действие в шапке экрана («Готово»).
    var link: Color
    var switchTrackOff: Color
    var switchThumbOff: Color
}

private enum Raw {
    static let cream = Color(hex: 0xF6F5F1)
    static let creamDeep = Color(hex: 0xE9E7E1)
    static let white = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x15171C)
    static let inkSoft = Color(hex: 0x3E434B)
    static let textSecondary = Color(hex: 0x5C626D)
    static let borderCard = Color(hex: 0xE5E2DA)
    static let divider = Color(hex: 0xECEAE4)
    static let teal = Color(hex: 0x0B6E69)
    static let tealContainer = Color(hex: 0xE3F0EE)
    static let tealOnContainer = Color(hex: 0x0B5450)
    static let tealDot = Color(hex: 0x1E8C7E)
    static let positive = Color(hex: 0x24501F)
    static let positiveContainer = Color(hex: 0xE8F1E6)
    static let warning = Color(hex: 0x6E4A00)
    static let warningContainer = Color(hex: 0xF8EFD9)
    static let negative = Color(hex: 0x8E2B18)
    static let negativeContainer = Color(hex: 0xFBE9E4)
    static let destructive = Color(hex: 0xB12E17)

    static let darkBackground = Color(hex: 0x0F1113)
    static let darkSurface = Color(hex: 0x1A1D21)
    static let darkSurfaceNested = Color(hex: 0x181B1F)
    static let darkSurfaceHigh = Color(hex: 0x23272C)
    static let darkSegmentSelected = Color(hex: 0x2E343B)
    static let darkBubble = Color(hex: 0x262B31)
    static let darkText = Color(hex: 0xEDECE7)
    static let darkTextSecondary = Color(hex: 0x9AA0A9)
    static let darkTextMuted = Color(hex: 0xC3C7CD)
    static let darkBorder = Color(hex: 0x2A2F35)
    static let darkAccent = Color(hex: 0x3FD1C2)
    static let darkOnAccent = Color(hex: 0x0E1114)
    static let darkAccentContainer = Color(hex: 0x123634)
    static let darkAccentOnContainer = Color(hex: 0x7FE3D8)
    static let darkEnd = Color(hex: 0xC8361C)
    static let darkPositiveContainer = Color(hex: 0x16291B)
    static let darkPositiveOnContainer = Color(hex: 0xA7E3B0)
    static let darkNegativeContainer = Color(hex: 0x351914)
    static let darkNegativeOnContainer = Color(hex: 0xF6B3A3)
    static let darkNegativeLabel = Color(hex: 0xF29A85)
    static let darkWarningContainer = Color(hex: 0x33270E)
    static let darkWarningOnContainer = Color(hex: 0xF0D08A)
}

/// Хорошая динамика в цифрах — например, у карточек KPI.
let positiveColor = Color(hex: 0x24501F)
/// Требует внимания.
let warningColor = Color(hex: 0x6E4A00)

extension Palette {
    static let light = Palette(
        primary: Raw.teal, onPrimary: Raw.white,
        primaryContainer: Raw.tealContainer, onPrimaryContainer: Raw.tealOnContainer,
        secondary: Raw.inkSoft,
        secondaryContainer: Raw.creamDeep, onSecondaryContainer: Raw.ink,
        tertiary: Raw.warning, tertiaryContainer: Raw.warningContainer, onTertiaryContainer: Raw.warning,
        background: Raw.cream, onBackground: Raw.ink,
        surface: Raw.cream, onSurface: Raw.ink,
        surfaceVariant: Raw.creamDeep, onSurfaceVariant: Raw.textSecondary,
        surfaceContainerLow: Raw.cream, surfaceContainer: Raw.white,
        surfaceContainerHigh: Raw.white, surfaceContainerHighest: Raw.creamDeep,
        outline: Raw.borderCard, outlineVariant: Raw.divider,
        error: Raw.destructive, onError: Raw.white,
        errorContainer: Raw.negativeContainer, onErrorContainer: Raw.negative,
        inverseSurface: Raw.ink, inverseOnSurface: Raw.cream,
        tones: ToneColors(
            positiveContainer: Raw.positiveContainer, positive: Raw.positive,
            negativeContainer: Raw.negativeContainer, negative: Raw.negative,
            warningContainer: Raw.warningContainer, warning: Raw.warning,
            connected: Raw.tealDot,
            segmentTrack: Raw.creamDeep, segmentSelected: Raw.white,
            link: Raw.teal,
            switchTrackOff: Raw.borderCard, switchThumbOff: Raw.white
        ),
        isDark: false
    )

    static let dark = Palette(
        primary: Raw.darkAccent, onPrimary: Raw.darkOnAccent,
        primaryContainer: Raw.darkAccentContainer, onPrimaryContainer: Raw.darkAccentOnContainer,
        secondary: Raw.darkTextMuted,
        secondaryContainer: Raw.darkSurfaceHigh, onSecondaryContainer: Raw.darkText,
        tertiary: Raw.darkWarningOnContainer, tertiaryContainer: Raw.darkWarningContainer,
        onTertiaryContainer: Raw.darkWarningOnContainer,
        background: Raw.darkBackground, onBackground: Raw.darkText,
        surface: Raw.darkBackground, onSurface: Raw.darkText,
        surfaceVariant: Raw.darkSurfaceHigh, onSurfaceVariant: Raw.darkTextSecondary,
        surfaceContainerLow: Raw.darkSurfaceNested, surfaceContainer: Raw.darkSurface,
        surfaceContainerHigh: Raw.darkSurfaceHigh, surfaceContainerHighest: Raw.darkBubble,
        outline: Raw.darkBorder, outlineVariant: Raw.darkBorder,
        error: Raw.darkNegativeLabel, onError: Raw.darkBackground,
        errorContainer: Raw.darkNegativeContainer, onErrorContainer: Raw.darkNegativeOnContainer,
        inverseSurface: Raw.darkText, inverseOnSurface: Raw.darkBackground,
        tones: ToneColors(
            positiveContainer: Raw.darkPositiveContainer, positive: Raw.darkPositiveOnContainer,
            negativeContainer: Raw.darkNegativeContainer, negative: Raw.darkNegativeOnContainer,
            warningContainer: Raw.darkWarningContainer, warning: Raw.darkWarningOnContainer,
            connected: Raw.darkAccent,
            segmentTrack: Raw.darkSurface, segmentSelected: Raw.darkSegmentSelected,
            link: Raw.darkAccentOnContainer,
            switchTrackOff: Raw.darkSegmentSelected, switchThumbOff: Raw.darkTextMuted
        ),
        isDark: true
    )

    /// Экран голоса — всегда тёмный; error там — кнопка «Завершить» (насыщенный красный с белым знаком).
    static let voice: Palette = {
        var palette = Palette.dark
        palette.error = Raw.darkEnd
        palette.onError = Raw.white
        return palette
    }()

    /// Знак Qanat — бирюзовый квадрат с тёмной буквой (как иконка приложения).
    static let brandAccent = Raw.darkAccent
    static let brandOnAccent = Raw.darkOnAccent
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Светлая/тёмная — по выбору пользователя ([AppTheme]) или по системе.
private struct QanatThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = scheme == .dark ? Palette.dark : Palette.light
        content
            .environment(\.palette, palette)
            .tint(palette.primary)
    }
}

extension View {
    func qanatTheme() -> some View { modifier(QanatThemeModifier()) }

    /// Экран голоса — всегда тёмный, независимо от выбранной темы приложения.
    func qanatVoiceTheme() -> some View {
        environment(\.palette, .voice)
            .environment(\.colorScheme, .dark)
            .tint(Palette.voice.primary)
    }
}
