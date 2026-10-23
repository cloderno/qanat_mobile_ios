import Foundation
import UIKit

/// Ошибки запросов снимков и видео к агенту — в [ChatError].
private func mapMediaErrors<T>(_ block: () async throws -> T) async throws -> T {
    do {
        return try await block()
    } catch let error as HTTPError {
        throw ChatError.server("HTTP \(error.code)")
    } catch is URLError {
        throw ChatError.network
    }
}

/// Удаление снимка или видео на сервере: 404 — его там уже нет, удалять больше нечего.
private func deleteUnlessGone(_ api: ApiClient, _ path: String) async throws {
    try await mapMediaErrors {
        do {
            _ = try await api.data(api.request("DELETE", path))
        } catch let error as HTTPError where error.code == 404 {
            return
        }
    }
}

final class PhotoRepositoryImpl: PhotoRepository {
    private let api: ApiClient
    // Плитки снимков в ленте чата: прокрутка туда-обратно не качает одно и то же заново.
    private let thumbnails = NSCache<NSString, NSData>()

    /// Сервер хранит фото до 2400 px по длинной стороне: мелкий текст документа агент читает по крупным частям снимка.
    private static let maxSide: CGFloat = 2400
    private static let jpegQuality: CGFloat = 0.9

    init(api: ApiClient) {
        self.api = api
        thumbnails.countLimit = 24
    }

    func upload(jpeg: Data, source: PhotoSource) async throws -> String {
        // Снимок с очков приходит в HEIC, а сервер проверяет реальный формат и HEIC отвергает. Поворот из метки EXIF
        // переносим в сами пиксели: UIImage его учитывает, а в новом JPEG метки нет.
        let real = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            guard let image = UIImage(data: jpeg) else {
                throw ChatError.server("Снимок не удалось перекодировать в JPEG (\(jpeg.count) байт)")
            }
            return Self.toJpeg(image)
        }.value
        return try await mapMediaErrors {
            var form = MultipartForm()
            form.addFile(name: "image", filename: "photo.jpg", mimeType: "image/jpeg", data: real)
            form.addField(name: "source", value: source.rawValue)
            let response = try JSONValue.parse(try await api.data(form.request(api.request("POST", "mobile/agent/photo"))))
            return response.string("uuid")
        }
    }

    func photo(id: String, thumbnail: Bool) async throws -> Data {
        if thumbnail, let cached = thumbnails.object(forKey: id as NSString) { return cached as Data }
        let jpeg = try await mapMediaErrors {
            try await api.data(api.request("GET", "agent/photos/\(id)", query: [URLQueryItem(name: "thumb", value: thumbnail ? "1" : "0")]))
        }
        if thumbnail { thumbnails.setObject(jpeg as NSData, forKey: id as NSString) }
        return jpeg
    }

    func delete(id: String) async throws {
        try await deleteUnlessGone(api, "mobile/agent/photo/\(id)")
        thumbnails.removeObject(forKey: id as NSString)
    }

    static func toJpeg(_ image: UIImage) -> Data {
        let longest = max(image.size.width, image.size.height)
        let ratio = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: max((image.size.width * ratio).rounded(), 1), height: max((image.size.height * ratio).rounded(), 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: jpegQuality) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

final class VideoRepositoryImpl: VideoRepository {
    private let api: ApiClient
    private let session: URLSession

    /// Сервер принимает видео до 10 МБ; точный предел в байтах не назван — берём меньший.
    private static let maxBytes = 10_000_000

    init(api: ApiClient) {
        self.api = api
        // Стандартного таймаута на загрузку видео мало — см. videoUploadTimeoutSeconds.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = videoUploadTimeoutSeconds
        configuration.timeoutIntervalForResource = videoUploadTimeoutSeconds
        session = URLSession(configuration: configuration)
    }

    func upload(video: URL) async throws -> String {
        let data = try Data(contentsOf: video)
        // Больше сервер не примет — не гоним мегабайты по сети, чтобы получить отказ.
        if data.count > Self.maxBytes { throw ChatError.server("Видео \(data.count) байт — больше лимита сервера") }
        return try await mapMediaErrors {
            var form = MultipartForm()
            form.addFile(name: "video", filename: video.lastPathComponent, mimeType: "video/mp4", data: data)
            // Видео в приложении снимают только очки.
            form.addField(name: "source", value: "glasses")
            var request = form.request(api.request("POST", "mobile/agent/video"))
            request.timeoutInterval = videoUploadTimeoutSeconds
            return try JSONValue.parse(try await api.data(request)).string("uuid")
        }
    }

    func delete(id: String) async throws {
        try await deleteUnlessGone(api, "mobile/agent/video/\(id)")
    }
}
