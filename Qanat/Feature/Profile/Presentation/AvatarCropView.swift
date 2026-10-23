import SwiftUI
import UIKit

/// Кадрирование выбранного фото под круг: двигают пальцем, увеличивают щипком. «Готово» отдаёт квадратный JPEG
/// не больше [maxAvatarSide] px.
struct AvatarCropView: View {
    let image: UIImage
    let onCropped: (Data) -> Void
    let onDismiss: () -> Void

    @Environment(\.windowLayout) private var layout
    @State private var frame: CropFrame?
    @State private var gestureBase: CropFrame?
    @State private var encoding = false

    private static let maxAvatarSide = 1024
    private static let jpegQuality: CGFloat = 0.9

    var body: some View {
        VStack(spacing: 0) {
            // Телефон боком: подсказка теснее — круг кадрирования и так получает меньше половины высоты.
            Text(L.t("avatar_crop_hint"))
                .textStyle(Typography.bodyMedium)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, layout.compactHeight ? Spacing.xs : Spacing.lg)
            GeometryReader { proxy in
                let viewport = max(min(proxy.size.width, proxy.size.height) - 2 * Spacing.lg, 1)
                let current = frame ?? CropFrame(imageWidth: pixelWidth, imageHeight: pixelHeight, viewport: viewport)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: CGFloat(pixelWidth) * current.scale, height: CGFloat(pixelHeight) * current.scale)
                        .offset(x: current.offsetX, y: current.offsetY)
                    // Затемнение вокруг круга.
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .mask {
                            Rectangle()
                                .overlay(Circle().frame(width: viewport, height: viewport).blendMode(.destinationOut))
                                .compositingGroup()
                        }
                    Circle().stroke(Color.white, lineWidth: 1).frame(width: viewport, height: viewport)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(DragGesture(), MagnifyGesture())
                        .onChanged { value in
                            let base = gestureBase ?? current
                            if gestureBase == nil { gestureBase = current }
                            let pan = value.first?.translation ?? .zero
                            let zoom = value.second?.magnification ?? 1
                            frame = base.transformed(panX: pan.width, panY: pan.height, zoomChange: zoom)
                        }
                        .onEnded { _ in gestureBase = nil }
                )
                .onChange(of: viewport) { _, newValue in
                    frame = CropFrame(imageWidth: pixelWidth, imageHeight: pixelHeight, viewport: newValue)
                }
                .onAppear { frame = current }
            }
            HStack {
                TextLinkButton(text: L.t("avatar_crop_cancel"), color: .white, action: onDismiss)
                Spacer()
                TextLinkButton(text: L.t("avatar_crop_done"), color: .white) {
                    guard !encoding, let frame else { return }
                    encoding = true
                    let square = frame.sourceSquare()
                    Task.detached(priority: .userInitiated) {
                        let jpeg = Self.cropToJpeg(image, square)
                        await MainActor.run { onCropped(jpeg) }
                    }
                }
                .disabled(encoding)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var pixelWidth: Int { image.cgImage?.width ?? Int(image.size.width) }
    private var pixelHeight: Int { image.cgImage?.height ?? Int(image.size.height) }

    private static func cropToJpeg(_ image: UIImage, _ square: SourceSquare) -> Data {
        guard let cg = image.cgImage,
              let cropped = cg.cropping(to: CGRect(x: square.left, y: square.top, width: square.side, height: square.side))
        else { return Data() }
        let side = min(square.side, maxAvatarSide)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        return renderer.jpegData(withCompressionQuality: jpegQuality) { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

extension UIImage {
    /// Фото из галереи может быть HEIC, повёрнуто меткой EXIF и в десятки мегапикселей: рисуем «как видно»
    /// и уменьшаем длинную сторону до [maxSide] — для кадрирования хватает.
    func normalized(maxSide: CGFloat = 2048) -> UIImage {
        let longest = max(size.width, size.height)
        let ratio = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
