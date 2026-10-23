import AVFoundation
import Combine
import SwiftUI

enum GalleryMessage: Equatable {
    case saved
    case deleted(Int)
}

@MainActor
@Observable
final class GalleryViewModel {
    private(set) var media: [CapturedMedia] = []
    /// Режим «Выбрать»: тап по плитке отмечает её, а сохранение и удаление — сразу для всех отмеченных.
    private(set) var isSelecting = false
    /// id отмеченных; вне режима выбора всегда пусто.
    private(set) var selectedIds: Set<String> = []
    /// Отмеченные сохраняются или удаляются — второй раз, пока не закончили, не запускаем.
    private(set) var isProcessing = false
    var errorKey: String?
    var message: GalleryMessage?

    private let repository: GlassesMediaRepository
    private let photos: PhotoRepository
    private let videos: VideoRepository
    private var subscription: AnyCancellable?

    init(repository: GlassesMediaRepository, photos: PhotoRepository, videos: VideoRepository) {
        self.repository = repository
        self.photos = photos
        self.videos = videos
        subscription = repository.media.receive(on: DispatchQueue.main).sink { [weak self] list in
            guard let self else { return }
            // Исчезнувшее из галереи отмеченным не остаётся — иначе счётчик врал бы.
            media = list
            selectedIds.formIntersection(list.map(\.id))
        }
    }

    /// Среди отмеченных есть загруженные Канату — при удалении можно убрать и их копии на сервере.
    var selectionHasServerCopies: Bool { media.contains { $0.serverId != nil && selectedIds.contains($0.id) } }

    func delete(_ item: CapturedMedia) {
        Task { try? await repository.delete(item) }
    }

    func exportToGallery(_ item: CapturedMedia) {
        Task {
            do {
                try await repository.exportToGallery(item)
                message = .saved
            } catch {
                errorKey = "glasses_error_export"
            }
        }
    }

    /// «Выбрать» и «Отмена» в шапке: и вход в режим выбора, и выход из него начинаются с пустого выбора.
    func toggleSelectionMode() {
        isSelecting.toggle()
        selectedIds = []
    }

    /// Долгое нажатие на плитку: включает выбор и отмечает её.
    func startSelection(with item: CapturedMedia) {
        if !isSelecting {
            isSelecting = true
            selectedIds = []
        }
        selectedIds.insert(item.id)
    }

    func toggleSelected(_ item: CapturedMedia) {
        guard isSelecting else { return }
        if selectedIds.contains(item.id) { selectedIds.remove(item.id) } else { selectedIds.insert(item.id) }
    }

    /// Заголовок дня и «Выбрать все»: отмечены все — снимаем отметку со всех, иначе отмечаем все.
    func toggleGroup(_ items: [CapturedMedia]) {
        guard isSelecting else { return }
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: selectedIds) { selectedIds.subtract(ids) } else { selectedIds.formUnion(ids) }
    }

    func exportSelected() {
        guard let selected = startProcessingSelected() else { return }
        Task {
            var saved: [CapturedMedia] = []
            for item in selected where (try? await repository.exportToGallery(item)) != nil { saved.append(item) }
            afterProcessing(saved)
            if saved.count == selected.count { message = .saved } else { errorKey = "glasses_error_export" }
        }
    }

    /// Подтверждение спрашивает экран: удаление необратимо. [alsoFromKanat] — удалить и копии на сервере;
    /// снимок, который там удалить не вышло, остаётся и на телефоне — отмеченным, чтобы повторить.
    func deleteSelected(alsoFromKanat: Bool) {
        guard let selected = startProcessingSelected() else { return }
        Task {
            var deleted: [CapturedMedia] = []
            for item in selected where await delete(item, alsoFromKanat: alsoFromKanat) { deleted.append(item) }
            afterProcessing(deleted)
            if !deleted.isEmpty { message = .deleted(deleted.count) }
            if deleted.count < selected.count { errorKey = "gallery_error_delete_server" }
        }
    }

    private func delete(_ item: CapturedMedia, alsoFromKanat: Bool) async -> Bool {
        if alsoFromKanat, let serverId = item.serverId {
            do {
                switch item.type {
                case .photo: try await photos.delete(id: serverId)
                case .video: try await videos.delete(id: serverId)
                }
            } catch {
                log.warning("Не удалось удалить у Каната \(item.type) \(serverId): \(error)")
                return false
            }
        }
        try? await repository.delete(item)
        return true
    }

    private func startProcessingSelected() -> [CapturedMedia]? {
        guard !isProcessing else { return nil }
        let selected = media.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        isProcessing = true
        return selected
    }

    /// Обработанные снимаются с отметки, неудавшиеся остаются отмеченными. Отмеченных не осталось — выбор закрывается.
    private func afterProcessing(_ done: [CapturedMedia]) {
        selectedIds.subtract(done.map(\.id))
        isProcessing = false
        isSelecting = isSelecting && !selectedIds.isEmpty
    }
}

private enum GalleryFilter: Int { case all, photo, video }

struct GalleryScreen: View {
    @State var viewModel: GalleryViewModel
    let onClose: () -> Void
    let onOpenGuide: () -> Void

    @State private var filter: GalleryFilter = .all
    @State private var confirmDelete = false
    @State private var alsoFromKanat = false
    @Environment(\.palette) private var palette
    @Environment(\.windowLayout) private var layout

    var body: some View {
        let visible = viewModel.media.filter { filter == .all || (filter == .photo ? $0.type == .photo : $0.type == .video) }
        VStack(spacing: 0) {
            ScreenTopBar(
                title: viewModel.isSelecting ? L.t("gallery_selected_title", viewModel.selectedIds.count) : L.t("gallery_title"),
                onBack: { viewModel.isSelecting ? viewModel.toggleSelectionMode() : onClose() }
            ) {
                if viewModel.isSelecting && !visible.isEmpty {
                    let allSelected = visible.allSatisfy { viewModel.selectedIds.contains($0.id) }
                    TextLinkButton(text: L.t(allSelected ? "gallery_deselect_all" : "gallery_select_all"), color: palette.tones.link, style: Typography.bodyMedium.weight(.semibold)) {
                        viewModel.toggleGroup(visible)
                    }
                }
                if viewModel.isSelecting || !viewModel.media.isEmpty {
                    TextLinkButton(text: L.t(viewModel.isSelecting ? "common_cancel" : "gallery_select"), color: palette.tones.link, style: Typography.bodyMedium.weight(.semibold), action: viewModel.toggleSelectionMode)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if visible.isEmpty {
                        EmptyMediaHint().padding(16)
                    } else {
                        grid(visible)
                    }
                }
                .padding(.bottom, 20)
            }
            if viewModel.isSelecting { selectionActions }
        }
        .background(palette.background)
        .snackbar(message: snackbarText) {
            viewModel.message = nil
            viewModel.errorKey = nil
        }
        .alert(L.plural("gallery_delete_dialog_title", viewModel.selectedIds.count), isPresented: $confirmDelete) {
            if viewModel.selectionHasServerCopies {
                Button(L.t("gallery_delete_from_kanat"), role: .destructive) { viewModel.deleteSelected(alsoFromKanat: true) }
            }
            Button(L.t("glasses_delete"), role: .destructive) { viewModel.deleteSelected(alsoFromKanat: false) }
            Button(L.t("common_cancel"), role: .cancel) {}
        } message: {
            Text(L.t("gallery_delete_dialog_text"))
        }
    }

    private var snackbarText: String? {
        if let key = viewModel.errorKey { return L.t(key) }
        switch viewModel.message {
        case .saved: return L.t("glasses_saved_to_gallery")
        case .deleted(let count): return L.plural("gallery_deleted", count)
        case nil: return nil
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            CaptureHintCard(action: onOpenGuide)
            SegmentedPicker(
                options: [L.t("gallery_tab_all"), L.t("gallery_tab_photo"), L.t("glasses_guide_tab_video")],
                selectedIndex: filter.rawValue,
                segmentHeight: 40,
                trackRadius: 14,
                segmentRadius: 10,
                onSelect: { filter = GalleryFilter(rawValue: $0) ?? .all }
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// Плиток в ряд — сколько влезает по 110pt, но не меньше трёх.
    private func grid(_ items: [CapturedMedia]) -> some View {
        let groups = items.groupedByDate { $0.capturedDate }
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]
        return LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(groups.enumerated()), id: \.element.0) { index, entry in
                let (group, groupMedia) = entry
                Section {
                    ForEach(groupMedia) { item in
                        MediaTile(
                            item: item,
                            selecting: viewModel.isSelecting,
                            selected: viewModel.selectedIds.contains(item.id),
                            onToggleSelected: { viewModel.toggleSelected(item) },
                            onLongPress: { viewModel.startSelection(with: item) },
                            onSave: { viewModel.exportToGallery(item) },
                            onDelete: { viewModel.delete(item) }
                        )
                    }
                } header: {
                    groupHeader(group.label, first: index == 0, items: groupMedia)
                }
            }
        }
    }

    /// Заголовок дня; в режиме выбора тап по нему отмечает весь день или снимает с него отметку.
    private func groupHeader(_ title: String, first: Bool, items: [CapturedMedia]) -> some View {
        let selected = items.allSatisfy { viewModel.selectedIds.contains($0.id) }
        return Button { viewModel.toggleGroup(items) } label: {
            HStack {
                Text(title).textStyle(Typography.labelLarge).foregroundStyle(palette.onSurface)
                Spacer()
                if viewModel.isSelecting { SelectionMark(selected: selected, onTile: false) }
            }
            .padding(.horizontal, 16)
            .padding(.top, first ? 0 : 11)
            .padding(.bottom, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isSelecting)
    }

    /// Действия режима выбора — сразу над всеми отмеченными; пока отмеченных нет или прошлое ещё идёт, неактивны.
    private var selectionActions: some View {
        let count = viewModel.selectedIds.count
        let enabled = count > 0 && !viewModel.isProcessing
        return VStack(spacing: 0) {
            if viewModel.isProcessing { ProgressView().progressViewStyle(.linear) } else { Rectangle().fill(palette.outlineVariant).frame(height: 1) }
            HStack {
                actionButton(L.t("gallery_save_selected", count), "square.and.arrow.down", palette.tones.link, enabled, viewModel.exportSelected)
                Spacer()
                actionButton(L.t("gallery_delete_selected", count), "trash", palette.error, enabled) { confirmDelete = true }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .background(palette.surfaceContainer)
    }

    private func actionButton(_ text: String, _ icon: String, _ color: Color, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17))
                Text(text).textStyle(Typography.bodyMedium.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .opacity(enabled ? 1 : 0.38)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Подсказка, как снимать кнопкой очков. В светлой теме карточка инвертирована, в тёмной — подложка с рамкой.
private struct CaptureHintCard: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let dark = palette.isDark
        let content = dark ? palette.onSurface : palette.inverseOnSurface
        Button(action: action) {
            HStack(spacing: 12) {
                GlassesIcon(tint: dark ? palette.primary : content).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("gallery_hint_title")).textStyle(Typography.bodyMedium.weight(.semibold)).foregroundStyle(content)
                    Text(L.t("gallery_hint_subtitle")).textStyle(Typography.labelMedium.weight(.regular))
                        .foregroundStyle(dark ? palette.onSurfaceVariant : content.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(dark ? palette.onSurfaceVariant : content)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(dark ? palette.surfaceContainer : palette.inverseSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { if dark { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.outline, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
    }
}

struct EmptyMediaHint: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill").font(.system(size: 28)).foregroundStyle(palette.onSurfaceVariant)
            Text(L.t("glasses_media_empty")).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Вне режима выбора тап открывает кнопки самой плитки, в режиме выбора — отмечает её.
private struct MediaTile: View {
    let item: CapturedMedia
    let selecting: Bool
    let selected: Bool
    let onToggleSelected: () -> Void
    let onLongPress: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(MediaThumbnail(item: item, showsDuration: true))
            .background(palette.surfaceContainerHigh)
            .clipped()
            .overlay {
                if selecting {
                    ZStack(alignment: .topTrailing) {
                        if selected { Color.black.opacity(0.3) }
                        SelectionMark(selected: selected, onTile: true).padding(6)
                    }
                } else if expanded {
                    HStack(spacing: 8) {
                        Button { onSave(); expanded = false } label: {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 20)).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(L.t("glasses_save_to_gallery"))
                        Button { onDelete(); expanded = false } label: {
                            Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(palette.error).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(L.t("glasses_delete"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if selecting { onToggleSelected() } else { expanded.toggle() } }
            .onLongPressGesture { onLongPress() }
            .onChange(of: selecting) { _, _ in expanded = false }
    }
}

/// Кружок в углу плитки: пустой — не отмечена, с галочкой — отмечена. Белый ободок виден на любом кадре.
private struct SelectionMark: View {
    let selected: Bool
    let onTile: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Circle().fill(selected ? palette.primary : (onTile ? Color.black.opacity(0.25) : .clear))
            Circle().stroke(onTile ? Color.white : (selected ? palette.primary : palette.outline), lineWidth: 1.5)
            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.onPrimary) }
        }
        .frame(width: 22, height: 22)
    }
}

/// Превью снимка или первый кадр видео — для плиток галереи и карточки на экране очков.
struct MediaThumbnail: View {
    let item: CapturedMedia
    var showsDuration = false

    @State private var image: UIImage?
    @State private var durationMs: Int64?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            if item.type == .video {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    if showsDuration, let durationMs {
                        Text(formatDuration(ms: durationMs)).font(Typography.labelSmall.weight(.semibold).font.monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .padding(6)
            }
        }
        .task(id: item.id) {
            let file = item.file
            if item.type == .photo {
                // Снимок очков в HEIC с меткой поворота: UIImage её учитывает.
                image = await Task.detached { UIImage(contentsOfFile: file.path)?.preparingThumbnail(of: CGSize(width: 360, height: 360)) }.value
            } else {
                let asset = AVURLAsset(url: file)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 360, height: 360)
                if let frame = try? await generator.image(at: .zero).image { image = UIImage(cgImage: frame) }
                if let duration = try? await asset.load(.duration) { durationMs = Int64(CMTimeGetSeconds(duration) * 1000) }
            }
        }
    }
}

private let log = Log("Gallery")
