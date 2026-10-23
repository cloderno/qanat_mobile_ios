import Combine
import Foundation
import Photos
import UserNotifications

/// Снимки и видео с очков лежат в хранилище приложения (Application Support) — не чистятся системой.
final class GlassesMediaRepositoryImpl: GlassesMediaRepository {
    private let preferencesStorage: PreferencesStorage
    private let directory: URL
    /// Вне папки снимков: та перечисляется как галерея.
    private let serverIdsFile: URL
    private let lock = NSLock()
    let media: CurrentValueSubject<[CapturedMedia], Never>

    init(preferencesStorage: PreferencesStorage) {
        self.preferencesStorage = preferencesStorage
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("glasses_media", isDirectory: true)
        serverIdsFile = support.appendingPathComponent("glasses_media_server_ids.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        media = CurrentValueSubject([])
        media.value = loadExisting()
    }

    func newVideoTempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("glasses_video_\(Self.nowMs()).mp4")
    }

    func savePhoto(_ data: Data) async throws -> CapturedMedia {
        let capturedAt = Self.nowMs()
        // Очки отдают снимок в HEIC: под именем .jpg он ушёл бы в галерею телефона как поддельный JPEG.
        let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
        let file = directory.appendingPathComponent("photo_\(capturedAt).\(ext)")
        try data.write(to: file, options: .atomic)
        let item = CapturedMedia(id: file.lastPathComponent, type: .photo, file: file, capturedAt: capturedAt)
        add(item)
        await exportIfEnabled(item)
        return item
    }

    func saveVideo(_ tempFile: URL) async throws -> CapturedMedia {
        let capturedAt = Self.nowMs()
        let file = directory.appendingPathComponent("video_\(capturedAt).mp4")
        try FileManager.default.moveItem(at: tempFile, to: file)
        let item = CapturedMedia(id: file.lastPathComponent, type: .video, file: file, capturedAt: capturedAt)
        add(item)
        await exportIfEnabled(item)
        return item
    }

    func rememberServerCopy(_ item: CapturedMedia, serverId: String) async {
        lock.withLock {
            media.value = media.value.map { $0.id == item.id ? CapturedMedia(id: $0.id, type: $0.type, file: $0.file, capturedAt: $0.capturedAt, serverId: serverId) : $0 }
        }
        saveServerIds()
    }

    func delete(_ item: CapturedMedia) async throws {
        try? FileManager.default.removeItem(at: item.file)
        lock.withLock { media.value = media.value.filter { $0.id != item.id } }
        saveServerIds()
    }

    func exportToGallery(_ item: CapturedMedia) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CocoaError(.userCancelled) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: item.type == .video ? .video : .photo, fileURL: item.file, options: nil)
            // Альбом «Qanat» — как папка Pictures/Qanat на Android; без доступа к чтению альбома ассет просто ляжет в «Недавние».
            if let album = Self.qanatAlbum(), let placeholder = request.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    /// Настройка «Сохранять в галерею»: копия — дополнение к снимку, её сбой съёмку не отменяет.
    private func exportIfEnabled(_ item: CapturedMedia) async {
        guard preferencesStorage.current().glassesSaveToGallery else { return }
        do {
            try await exportToGallery(item)
        } catch {
            log.warning("Не удалось скопировать \(item.id) в галерею телефона: \(error)")
        }
    }

    private static func qanatAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", "Qanat")
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
    }

    private func add(_ item: CapturedMedia) {
        lock.withLock { media.value = (media.value + [item]).sorted { $0.capturedAt > $1.capturedAt } }
    }

    /// Целиком и атомарно: оборванная запись не испортит прежний список.
    private func saveServerIds() {
        let ids = lock.withLock { Dictionary(media.value.compactMap { item in item.serverId.map { (item.id, $0) } }, uniquingKeysWith: { $1 }) }
        do {
            try JSONEncoder().encode(ids).write(to: serverIdsFile, options: .atomic)
        } catch {
            log.warning("Не удалось запомнить снимки, загруженные Канату: \(error)")
        }
    }

    private func loadExisting() -> [CapturedMedia] {
        // Без списка id галерея всё равно открывается — пропадёт лишь возможность удалить снимки и у Каната.
        var ids: [String: String] = [:]
        if let data = try? Data(contentsOf: serverIdsFile) {
            ids = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { file -> CapturedMedia? in
            let name = file.lastPathComponent
            let type: CapturedMedia.Kind
            if name.hasPrefix("photo_") { type = .photo } else if name.hasPrefix("video_") { type = .video } else { return nil }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return CapturedMedia(id: name, type: type, file: file, capturedAt: Int64(modified.timeIntervalSince1970 * 1000), serverId: ids[name])
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// Звуковые сигналы для фото/видео с кнопки очков и проверки очков — тона отличаются от голосовых сигналов.
enum GlassesSignal { case videoStarted, videoStopped, failed, check }

protocol GlassesSignals: AnyObject {
    func play(_ signal: GlassesSignal) async
}

final class GlassesSignalPlayer: GlassesSignals {
    private let tones: TonePlayer

    init(tones: TonePlayer) { self.tones = tones }

    func play(_ signal: GlassesSignal) async {
        let notes: [Tone] = switch signal {
        case .videoStarted: [Tone(frequencyHz: 740, durationMs: 120)]
        case .videoStopped: [Tone(frequencyHz: 494, durationMs: 120)]
        // Как у неудачной голосовой команды: сбой звучит одинаково, что бы ни сломалось.
        case .failed: failureTones
        // Проверка звука в очках: два «динь-дон», а перед ними тишина — пока Bluetooth будит канал к очкам.
        case .check: [
            Tone(frequencyHz: 0, durationMs: 300), Tone(frequencyHz: 880, durationMs: 200), Tone(frequencyHz: 1318.5, durationMs: 200),
            Tone(frequencyHz: 0, durationMs: 150), Tone(frequencyHz: 880, durationMs: 200), Tone(frequencyHz: 1318.5, durationMs: 200),
        ]
        }
        await tones.play(notes)
    }
}

/// Страница Meta AI в App Store: прошивку очков и приложение Qanat на них обновляют через Meta AI.
let metaAiStoreURL = URL(string: "https://apps.apple.com/app/meta-ai/id1558240027")!

/// Очки не пускают Qanat, пока в Meta AI не обновят прошивку очков или приложение Qanat на них.
func needsMetaAiUpdate(_ failure: GlassesLinkFailure?, _ device: GlassesDeviceInfo?) -> Bool {
    failure == .glassesAppOutdated || device?.updateRequired == .glasses
}

/// Уведомление «обновите Meta AI», пока очки не пускают Qanat из-за версий. Без него пользователь слышит только
/// повторяющийся сигнал связи на очках и не знает причину.
@MainActor
final class MetaAiUpdateNotice {
    private let glasses: GlassesControls
    private let link: GlassesLink
    private static let identifier = "meta_ai_update"

    init(glasses: GlassesControls, link: GlassesLink) {
        self.glasses = glasses
        self.link = link
    }

    func run() async {
        defer { Self.cancel() }
        let needed = link.failure.combineLatest(glasses.deviceInfo).map { needsMetaAiUpdate($0, $1) }.removeDuplicates()
        for await need in needed.values {
            if need { Self.show() } else { Self.cancel() }
        }
    }

    private static func show() {
        let content = UNMutableNotificationContent()
        content.title = L.t("meta_ai_update_notice_title")
        content.body = L.t("meta_ai_update_notice_text")
        content.userInfo = ["open_url": metaAiStoreURL.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // Вышли из аккаунта — уведомление о чужих очках не оставляем.
    private static func cancel() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

private let log = Log("GlassesMedia")
