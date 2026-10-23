import SwiftUI

/// Карточки с цифрами: на телефоне по две в ряд, на широкой карточке — по три и по четыре ([kpiColumns]).
/// [columns] — сколько в ряд, если решает родитель (дашборд); nil — по ширине самих карточек.
/// Плитки ряда одной высоты: мини-графики и полосы стоят по низу.
struct KpiCards: View {
    let items: [Kpi]
    var columns: Int?

    @State private var width: CGFloat = 0

    var body: some View {
        // Плиток меньше, чем мест в ряду, — делят ряд между собой, а не стоят четвертинками с пустотой справа.
        let perRow = max(min(columns ?? kpiColumns(width), items.count), 1)
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: perRow)), id: \.self) { start in
                let row = Array(items[start..<min(start + perRow, items.count)])
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row.indices, id: \.self) { index in
                        KpiTile(kpi: row[index]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Неполный последний ряд — плитки той же ширины, что и выше.
                    ForEach(0..<(perRow - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new } })
    }
}

/// Плиток в ряду по ширине, pt: 2 на телефоне, 3 от 600, 4 от 840.
func kpiColumns(_ width: CGFloat) -> Int {
    if width >= 840 { return 4 }
    if width >= 600 { return 3 }
    return 2
}

private struct KpiTile: View {
    let kpi: Kpi

    @State private var appearance: CGFloat = 0
    @Environment(\.palette) private var palette

    var body: some View {
        let (background, foreground) = toneColors(kpi.tone, palette)
        // У нейтральной плитки подпись приглушённая, а само число — обычным цветом текста.
        let valueColor = kpi.tone == .neutral ? palette.onSurface : foreground
        // Мини-график и полоса нейтральной плитки — фирменным цветом: серые они теряются на сером.
        let accent = kpi.tone == .neutral ? palette.primary : foreground
        let spark = sparkPoints(kpi.spark)
        VStack(alignment: .leading, spacing: 0) {
            Text(kpi.label).textStyle(Typography.labelMedium.weight(.regular)).foregroundStyle(foreground)
            Text(kpi.value)
                .font(Typography.titleLarge.size(22).font.monospacedDigit())
                .foregroundStyle(valueColor)
                .padding(.top, 2)
            if let delta = kpi.delta { DeltaBadge(delta: delta, tone: kpi.deltaTone).padding(.top, 4) }
            if !kpi.hint.isEmpty {
                Text(kpi.hint).textStyle(Typography.bodySmall).foregroundStyle(foreground).padding(.top, 4)
            }
            if !spark.isEmpty || kpi.progress != nil { Spacer(minLength: 0) }
            if !spark.isEmpty {
                Sparkline(points: spark, color: accent, background: background, drawn: appearance)
                    .frame(height: 36)
                    .padding(.top, 8)
            }
            if let progress = kpi.progress {
                KpiProgress(percent: progress, color: accent, labelColor: foreground, drawn: appearance).padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        // VoiceOver читает плитку целиком: подпись, число, изменение, пояснение, процент.
        .accessibilityElement(children: .combine)
        .onAppear { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.9)) { appearance = 1 } }
    }
}

/// Изменение в капсуле: стрелка — по знаку, цвет — по [tone]: хорошо это или плохо, решает сервер, а не знак.
private struct DeltaBadge: View {
    let delta: String
    let tone: Kpi.Tone

    @Environment(\.palette) private var palette

    var body: some View {
        let color = toneColors(tone, palette).1
        let arrow = deltaArrow(delta)
        HStack(spacing: 2) {
            // Знак есть и в самом тексте, поэтому стрелка для VoiceOver — украшение.
            if arrow != .none {
                Image(systemName: arrow == .up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(delta).font(Typography.labelMedium.font.monospacedDigit()).foregroundStyle(color)
        }
        .padding(.leading, arrow != .none ? 5 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.extraSmall, style: .continuous))
    }
}

/// Доля [percent] из 100 — полоса и подпись «87 %»; полоса заполняется, пока плитка проявляется.
private struct KpiProgress: View {
    let percent: Int
    let color: Color
    let labelColor: Color
    let drawn: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                let height = proxy.size.height
                let filled = proxy.size.width * CGFloat(percent) / 100 * drawn
                ZStack(alignment: .leading) {
                    // Дорожка — тот же цвет, только светлее: видно, сколько осталось до 100.
                    Capsule().fill(color.opacity(0.18))
                    // Малая доля — хотя бы точкой, а не волоском.
                    if filled > 0 { Capsule().fill(color).frame(width: max(filled, height)) }
                }
            }
            .frame(height: 6)
            Text((Double(percent) / 100).formatted(.percent.locale(LanguageSettings.shared.language.locale)))
                .font(Typography.labelMedium.font.monospacedDigit())
                .foregroundStyle(labelColor)
        }
    }
}

/// Куда смотрит стрелка у изменения.
enum DeltaArrow { case up, down, none }

/// По знаку в начале: «+12%» — вверх; «-3», «−3» (минус U+2212), «–3» (тире U+2013) — вниз; без знака — без стрелки.
func deltaArrow(_ delta: String) -> DeltaArrow {
    switch delta.drop(while: { $0.isWhitespace }).first {
    case "+": .up
    case "-", "\u{2212}", "\u{2013}": .down
    default: .none
    }
}

private func toneColors(_ tone: Kpi.Tone, _ palette: Palette) -> (Color, Color) {
    switch tone {
    case .good: (palette.tones.positiveContainer, palette.tones.positive)
    case .bad: (palette.tones.negativeContainer, palette.tones.negative)
    case .warn: (palette.tones.warningContainer, palette.tones.warning)
    case .neutral: (palette.surfaceVariant, palette.onSurfaceVariant)
    }
}
