import SwiftUI

/// Снимки к вопросу — плитками в ряд; нажали на плитку — показать снимок целиком ([PhotoViewer]).
struct MessagePhotos: View {
    let photos: [ChatPhoto]
    let actions: MessageActions

    /// Сервер принимает к вопросу до четырёх снимков.
    private static let maxPhotos = 4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(photos.prefix(Self.maxPhotos), id: \.id) { photo in
                PhotoTile(id: photo.id, actions: actions)
            }
        }
    }
}

/// Пока снимок грузится, плитка пустая. У снимка вопроса, который сервер ещё не сохранил, настоящего id нет —
/// такой не грузим и не открываем.
private struct PhotoTile: View {
    let id: String
    let actions: MessageActions

    @State private var phase: PhotoPhase = .loading

    var body: some View {
        let saved = id != localPhotoId
        Button { actions.onOpenPhoto(id) } label: {
            ZStack {
                // Нейтральная подложка в цвет текста пузыря — заметна и на светлом, и на тёмном.
                Rectangle().fill(.primary.opacity(0.12))
                if saved {
                    switch phase {
                    case .loading: EmptyView()
                    case .loaded(let image): Image(uiImage: image).resizable().scaledToFill()
                    case .failed: Image(systemName: "photo.badge.exclamationmark").font(.system(size: 18)).opacity(0.6)
                    }
                }
            }
            .frame(maxWidth: 56)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
        .disabled(!saved)
        .accessibilityLabel(L.t("chat_attached_photo"))
        .task(id: id) {
            guard saved else { return }
            phase = await loadPhase(id: id, thumbnail: true, load: actions.loadPhoto)
        }
    }
}

enum PhotoPhase {
    case loading
    case loaded(UIImage)
    case failed
}

/// Снимок грузится и разбирается в фоне: разбор JPEG на главном потоке подтормаживал бы прокрутку ленты.
func loadPhase(id: String, thumbnail: Bool, load: (String, Bool) async -> Data?) async -> PhotoPhase {
    guard let jpeg = await load(id, thumbnail) else { return .failed }
    let image = await Task.detached(priority: .userInitiated) { UIImage(data: jpeg)?.preparingForDisplay() }.value
    return image.map { .loaded($0) } ?? .failed
}

/// Весь снимок на чёрном фоне; закрывается нажатием в любом месте.
struct PhotoViewer: View {
    let id: String
    let load: (String, Bool) async -> Data?
    let onDismiss: () -> Void

    @State private var phase: PhotoPhase = .loading

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .loading: ProgressView().tint(.white)
            case .loaded(let image):
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(L.t("chat_attached_photo"))
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 36)).foregroundStyle(.white)
                    Text(L.t("chat_error_photo")).textStyle(Typography.bodyMedium).foregroundStyle(.white)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .task(id: id) { phase = await loadPhase(id: id, thumbnail: false, load: load) }
    }
}
