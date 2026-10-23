import CoreGraphics

/// Кадр под круглое фото: картинка [imageWidth]×[imageHeight] на экране всегда целиком закрывает круг
/// диаметром [viewport] pt. [zoom] от 1 (короткая сторона во весь круг) до [maxZoom];
/// [offsetX]/[offsetY] — сдвиг центра картинки от центра круга в pt экрана.
struct CropFrame: Equatable {
    static let maxZoom: CGFloat = 5

    let imageWidth: Int
    let imageHeight: Int
    let viewport: CGFloat
    var zoom: CGFloat = 1
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0

    /// Точек экрана на пиксель картинки.
    var scale: CGFloat { viewport / CGFloat(min(imageWidth, imageHeight)) * zoom }

    /// Жест: сдвиг пальцами и щипок. Увеличиваем вокруг центра круга и не даём краю картинки зайти в круг.
    func transformed(panX: CGFloat, panY: CGFloat, zoomChange: CGFloat) -> CropFrame {
        let newZoom = min(max(zoom * zoomChange, 1), Self.maxZoom)
        let ratio = newZoom / zoom
        var zoomed = self
        zoomed.zoom = newZoom
        let maxX = (CGFloat(imageWidth) * zoomed.scale - viewport) / 2
        let maxY = (CGFloat(imageHeight) * zoomed.scale - viewport) / 2
        zoomed.offsetX = min(max(offsetX * ratio + panX, -maxX), maxX)
        zoomed.offsetY = min(max(offsetY * ratio + panY, -maxY), maxY)
        return zoomed
    }

    /// Квадрат картинки под кругом, в её пикселях.
    func sourceSquare() -> SourceSquare {
        let side = min(max(Int((viewport / scale).rounded(.down)), 1), min(imageWidth, imageHeight))
        let centerX = CGFloat(imageWidth) / 2 - offsetX / scale
        let centerY = CGFloat(imageHeight) / 2 - offsetY / scale
        return SourceSquare(
            left: min(max(Int((centerX - CGFloat(side) / 2).rounded()), 0), imageWidth - side),
            top: min(max(Int((centerY - CGFloat(side) / 2).rounded()), 0), imageHeight - side),
            side: side
        )
    }
}

struct SourceSquare: Equatable {
    let left: Int
    let top: Int
    let side: Int
}
