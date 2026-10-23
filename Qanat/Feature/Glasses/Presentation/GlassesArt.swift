import SwiftUI
import UIKit

// Рендеры одни для обеих тем: оправа чёрная, а блики по краю видны и на тёмном фоне. Картинки декоративные.

/// Картинка из Resources/Images (webp): UIImage читает его с диска, каталог ассетов webp не принимает.
private func bundledImage(_ name: String) -> UIImage? {
    Bundle.main.url(forResource: name, withExtension: "webp").flatMap { UIImage(contentsOfFile: $0.path) }
}

private let heroImage = bundledImage("glasses_hero")
private let heroBadgeImage = bundledImage("glasses_hero_badge")
private let templeImage = bundledImage("glasses_temple")

/// Очки три четверти спереди — на карточке устройства.
struct GlassesFrontArt: View {
    var body: some View {
        if let heroImage { Image(uiImage: heroImage).resizable().scaledToFit().accessibilityHidden(true) }
    }
}

/// Те же очки в плитке 56pt на экране подключения — из заранее уменьшенной копии: полный рендер рябит.
struct GlassesBadgeArt: View {
    var body: some View {
        if let heroBadgeImage { Image(uiImage: heroBadgeImage).resizable().scaledToFit().accessibilityHidden(true) }
    }
}

/// Очки ещё не подключены: тот же рендер, серый и полупрозрачный.
struct GlassesDimmedArt: View {
    @Environment(\.palette) private var palette

    var body: some View {
        if let heroImage {
            Image(uiImage: heroImage).resizable().scaledToFit().grayscale(1).opacity(palette.isDark ? 0.55 : 0.45).accessibilityHidden(true)
        }
    }
}

/// Правая дужка сбоку: кнопка камеры у шарнира и пульсирующее «нажатие» на ней.
struct GlassesTempleArt: View {
    @Environment(\.palette) private var palette

    // Центр кнопки в долях рисунка — снят с самого рендера; кольцо — в долях ширины рисунка.
    private static let buttonX: CGFloat = 0.6824
    private static let buttonY: CGFloat = 0.382
    private static let ringRadius: CGFloat = 0.05
    private static let ringStroke: CGFloat = 0.0094

    var body: some View {
        if let templeImage {
            GeometryReader { proxy in
                let image = fittedImageRect(templeImage.size, in: proxy.size)
                TimelineView(.animation) { context in
                    let tap = CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
                    let eased = 1 - pow(1 - tap, 3)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: templeImage).resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                        // Кольцо привязано к кнопке на самом рисунке, а не к рамке.
                        Circle()
                            .stroke(palette.primary, lineWidth: image.width * Self.ringStroke)
                            .frame(width: image.width * Self.ringRadius * 2, height: image.width * Self.ringRadius * 2)
                            .scaleEffect(0.7 + 1.1 * eased)
                            .opacity(0.8 * (1 - eased))
                            .position(x: image.minX + image.width * Self.buttonX, y: image.minY + image.height * Self.buttonY)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Где внутри [box] окажется картинка размера [image] при вписывании по центру.
func fittedImageRect(_ image: CGSize, in box: CGSize) -> CGRect {
    let scale = min(box.width / image.width, box.height / image.height)
    let fitted = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(origin: CGPoint(x: (box.width - fitted.width) / 2, y: (box.height - fitted.height) / 2), size: fitted)
}
