import SwiftUI
import UIKit

/// Картинки с сервера: с токеном (фото чатов, аватары, превью документов закрыты авторизацией) и кешем в памяти.
/// Аналог Coil с OkHttp-клиентом приложения.
final class ImageLoader {
    static var shared: ImageLoader!

    private let api: ApiClient
    private let cache = NSCache<NSURL, UIImage>()

    init(api: ApiClient) {
        self.api = api
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async throws -> UIImage {
        if let image = cached(url) { return image }
        // Свой сервер — с токеном; чужие адреса — как есть.
        let data: Data
        if url.host == api.baseURL.host {
            data = try await api.data(URLRequest(url: url))
        } else {
            data = try await api.session.data(from: url).0
        }
        guard let image = UIImage(data: data) else { throw UnexpectedResponseError(underlying: URLError(.cannotDecodeContentData)) }
        cache.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    func remember(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: ImageLoader.shared?.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard image == nil || ImageLoader.shared.cached(url) == nil else { return }
            image = try? await ImageLoader.shared.image(url)
        }
    }
}
