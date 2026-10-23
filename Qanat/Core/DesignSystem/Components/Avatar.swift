import SwiftUI

/// Круглое фото пользователя. Под ним всегда инициалы: пока фото нет, оно грузится или не загрузилось — видны они.
/// [imageURL] — полный адрес фото с сервера; размер под круг дописываем сами.
struct Avatar: View {
    let initials: String
    let imageURL: String?
    let size: CGFloat
    let textStyle: QTextStyle

    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Circle().fill(palette.inverseSurface)
            Text(initials).textStyle(textStyle).foregroundStyle(palette.inverseOnSurface)
            if let imageURL, let url = URL(string: avatarURLForSize(imageURL, sizePx: Int(size * scale))) {
                RemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Сервер отдаёт фото 512 px, а по `s=64|128|256` — уменьшенное: берём наименьшее, что не мельче круга.
func avatarURLForSize(_ url: String, sizePx: Int) -> String {
    guard let side = [64, 128, 256].first(where: { $0 >= sizePx }) else { return url }
    return url + (url.contains("?") ? "&" : "?") + "s=\(side)"
}

/// Та же пиктограмма очков, что в макете (два кружка на дужке), — в SF Symbols такой нет.
struct GlassesIcon: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            var path = Path()
            path.addEllipse(in: CGRect(x: (6.5 - 3.5) * scale, y: (14 - 3.5) * scale, width: 7 * scale, height: 7 * scale))
            path.addEllipse(in: CGRect(x: (17.5 - 3.5) * scale, y: (14 - 3.5) * scale, width: 7 * scale, height: 7 * scale))
            path.move(to: pt(10, 14)); path.addLine(to: pt(14, 14))
            path.move(to: pt(3, 13)); path.addLine(to: pt(4.5, 8))
            path.move(to: pt(21, 13)); path.addLine(to: pt(19.5, 8))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round))
        }
    }
}

/// Волна голосового режима — чтобы не путать с микрофоном голосового сообщения (ic_voice_mode на Android).
struct VoiceModeIcon: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let bars: [(CGFloat, CGFloat, CGFloat)] = [(3, 10.5, 13.5), (7, 7.5, 16.5), (11, 4, 20), (15, 7.5, 16.5), (19, 10.5, 13.5)]
            for (x, top, bottom) in bars {
                let rect = CGRect(x: x * scale, y: (top - 1) * scale, width: 2 * scale, height: (bottom - top + 2) * scale)
                context.fill(Path(roundedRect: rect, cornerRadius: scale), with: .color(tint))
            }
        }
    }
}
