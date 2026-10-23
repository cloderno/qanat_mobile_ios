import SwiftUI

/// Какой экран под приложением. [compactHeight] — телефон боком: шапки ниже, поле ввода в одну строку.
/// [twoPane] — ширины хватает на список чатов рядом с перепиской, как на сайте.
/// [landscape] — окно шире, чем выше: только тогда есть место ставить блоки рядом, а не друг под другом.
struct WindowLayout: Equatable {
    var compactHeight = false
    var twoPane = false
    var landscape = false

    /// Высота шапок: обычная 56pt, телефон боком — 48pt, ровно под кнопку.
    var topBarHeight: CGFloat { compactHeight ? 48 : 56 }

    init(compactHeight: Bool = false, twoPane: Bool = false, landscape: Bool = false) {
        self.compactHeight = compactHeight
        self.twoPane = twoPane
        self.landscape = landscape
    }

    init(size: CGSize) {
        compactHeight = size.height < compactHeightLimit
        twoPane = size.width >= twoPaneWidth
        landscape = size.width > size.height
    }
}

/// Ниже — телефон боком: стандартные шапки и поля съедают полэкрана.
let compactHeightLimit: CGFloat = 480
/// С этой ширины (телефон боком, планшет) список чатов стоит постоянной колонкой слева.
let twoPaneWidth: CGFloat = 600
let maxContentWidth: CGFloat = 600

private struct WindowLayoutKey: EnvironmentKey {
    static let defaultValue = WindowLayout()
}

extension EnvironmentValues {
    var windowLayout: WindowLayout {
        get { self[WindowLayoutKey.self] }
        set { self[WindowLayoutKey.self] = newValue }
    }
}

extension View {
    /// Формы и списки настроек на широком экране — не шире [maxContentWidth] и по центру.
    func readableWidth() -> some View {
        frame(maxWidth: maxContentWidth).frame(maxWidth: .infinity)
    }

    /// Меряет окно и кладёт [WindowLayout] в окружение — ставится на корень.
    func measuresWindowLayout() -> some View {
        GeometryReader { proxy in
            self.environment(\.windowLayout, WindowLayout(size: proxy.size))
        }
    }
}
