import Combine
import Foundation

struct CapturedMedia: Equatable, Identifiable, Hashable {
    enum Kind: String { case photo, video }

    let id: String
    let type: Kind
    let file: URL
    /// Когда снято, мс с 1970.
    let capturedAt: Int64
    /// UUID копии у Каната — если снимок или видео уходили на сервер.
    var serverId: String?

    var capturedDate: Date { Date(timeIntervalSince1970: TimeInterval(capturedAt) / 1000) }
}

/// Фото и видео с очков. Хранятся в приложении; в галерею телефона — по запросу, а при включённой настройке
/// glassesSaveToGallery — сразу при сохранении.
protocol GlassesMediaRepository: AnyObject {
    var media: CurrentValueSubject<[CapturedMedia], Never> { get }

    /// Файл для текущей записи видео — пишем прямо в него, пока снимаем.
    func newVideoTempFile() -> URL

    /// Сбой копии в галерею телефона сохранение не роняет.
    func savePhoto(_ data: Data) async throws -> CapturedMedia

    /// [tempFile] уже записан на диск — переносим его в хранилище фичи.
    func saveVideo(_ tempFile: URL) async throws -> CapturedMedia

    /// Снимок или видео загружены Канату под UUID [serverId] — запоминаем, чтобы при удалении убрать и там.
    func rememberServerCopy(_ media: CapturedMedia, serverId: String) async

    func delete(_ media: CapturedMedia) async throws

    /// Копирует файл в «Фото» — виден в обычной галерее телефона.
    func exportToGallery(_ media: CapturedMedia) async throws
}

/// Ошибка, о которой сообщил Meta SDK при подключении или отвязке Qanat в Meta AI.
enum GlassesRegistrationError: Equatable {
    /// Meta AI считает Qanat уже подключённым — например, осталось подключение от прошлой установки.
    case alreadyRegistered
    /// Отвязывать нечего — Qanat в Meta AI уже не подключён.
    case alreadyUnregistered
    /// Любая другая ошибка: Meta AI не установлен, отказ, неизвестная причина.
    case other
}

/// Где сейчас подключение Qanat в Meta AI, по словам Meta SDK.
enum GlassesRegistrationState: Equatable {
    /// Подключаться сейчас некуда: SDK не готов или Meta AI недоступен.
    case unavailable
    /// Не подключён, можно подключать.
    case available
    /// Meta AI ответил, SDK заканчивает подключение.
    case registering
    case registered
    /// SDK заканчивает отвязку.
    case unregistering
}

/// Подключение Qanat к очкам глазами Meta SDK.
protocol GlassesRegistrationStatus: AnyObject {
    /// Текущее состояние; новый подписчик сразу получает последнее.
    var state: AnyPublisher<GlassesRegistrationState, Never> { get }
    /// Ошибки. Поток горячий: ошибки до подписки не повторяются.
    var errors: AnyPublisher<GlassesRegistrationError, Never> { get }
}
