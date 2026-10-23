import Combine
import Foundation

/// Управление приложением с самих очков. Общий контракт для фич voice, settings и glasses.
protocol GlassesControls: AnyObject {
    /// Приложение подключено к очкам через Meta AI и может получать их события.
    var isRegistered: AnyPublisher<Bool, Never> { get }

    /// Жесты кнопкой камеры на очках. Пока на поток подписаны, держится сессия с очками;
    /// если очки отключились или сессия оборвалась, подключение повторяется само.
    var captureButtonGestures: AnyPublisher<GlassesGesture, Never> { get }

    /// Имя очков и на связи ли они. nil, если Qanat не подключён к очкам через Meta AI или ни одни очки ещё не известны.
    var deviceInfo: AnyPublisher<GlassesDeviceInfo?, Never> { get }

    /// Последнее известное состояние очков — без подписки.
    var currentDeviceInfo: GlassesDeviceInfo? { get }

    /// Возвращается, когда очки сняли. Связь с ними при этом не рвётся, поэтому без датчика ношения разговор
    /// продолжался бы на снятых очках. Очки без датчика и отключённые снятыми не считаются.
    func awaitTakenOff() async
}

/// На связи ли Qanat с очками. Подписка сюда сессию с очками не держит.
protocol GlassesLink: AnyObject {
    /// Сессия Qanat с очками запущена: кнопка и камера очков работают на Qanat, а не только на Meta AI.
    var isLinked: CurrentValueSubject<Bool, Never> { get }

    /// Последнее начало связи Qanat с очками за процесс; nil — связи ещё не было.
    var lastStart: CurrentValueSubject<GlassesLinkStart?, Never> { get }

    /// Почему последние попытки связи не удались — по ошибке, которую можно назвать пользователю.
    var failure: CurrentValueSubject<GlassesLinkFailure?, Never> { get }
}

/// Ошибка сессии с очками, которую может исправить пользователь.
enum GlassesLinkFailure: Equatable {
    /// Очки отклонили сессию как неразрешённую.
    case notAllowed
    /// Приложению Qanat на очках нужно обновление — в Meta AI, среди подключённых приложений.
    case glassesAppOutdated
    /// Приложение Qanat на очках не запустилось: не установлено или очки не настроены в Meta AI.
    case glassesAppUnavailable
    /// Очки больше не поддерживают SDK этой версии Qanat.
    case qanatOutdated
    case batteryLow
    case overheated
}

/// Начало связи: [number] — какая она по счёту за процесс; [gapMs] — сколько перед ней связи не было, nil — первая.
struct GlassesLinkStart: Equatable {
    let number: Int
    let gapMs: Int64?
}

/// Состояние самих очков, как его показывает экран «Смарт-очки».
struct GlassesDeviceInfo: Equatable {
    var name: String
    var isConnected: Bool
    /// Заряд очков в процентах; nil — очки ещё не прислали показание. Заряд кейса SDK не отдаёт.
    var batteryLevel: Int?
    var isCharging = false
    /// Надеты ли очки; nil — неизвестно.
    var isWorn: Bool?
    /// Дужки сложены; nil — неизвестно.
    var isFolded: Bool?
    /// Что обновить, чтобы очки работали с Qanat; nil — ничего.
    var updateRequired: GlassesUpdate?
}

/// Что обновить, когда версии очков и Qanat не сходятся.
enum GlassesUpdate: Equatable {
    /// Прошивку очков — в Meta AI.
    case glasses
    /// Сам Qanat: его версию SDK очки уже не поддерживают.
    case qanat
}

/// Что с очками сейчас — для подписей статуса. Приложение работает и без очков.
enum GlassesStatus: Equatable {
    /// Очки не добавлены: Qanat не подключён к ним через Meta AI или SDK не знает ни одних очков.
    case notConnected
    /// Подключён, но очков сейчас нет на связи: выключены, в кейсе, далеко.
    case offline
    /// На связи, но сняты.
    case takenOff
    /// На связи, а надеты ли — неизвестно.
    case connected
    /// На связи и надеты: ими управляют и в них говорят.
    case ready
}

func glassesStatus(registered: Bool, info: GlassesDeviceInfo?) -> GlassesStatus {
    guard registered, let info else { return .notConnected }
    if !info.isConnected { return .offline }
    switch info.isWorn {
    case false: return .takenOff
    case true: return .ready
    default: return .connected
    }
}

/// Съёмка кнопкой камеры очков: одиночное нажатие — фото, удержание — видео.
protocol GlassesCamera: AnyObject {
    /// Снимок с очков. [full] — в полном разрешении камеры, если она свободна; false — сразу кадр из потока.
    func capturePhoto(full: Bool) async throws -> Data

    /// Пишет сжатое видео (без звука) в [outputFile], пока не вызовут [stopVideo]. Возвращается, когда в файл лёг
    /// первый кадр. [joinRunning] — писать только с уже включённой камеры голосового или разговора.
    func startVideo(outputFile: URL, joinRunning: Bool) async throws

    /// Завершает запись и возвращает готовый файл. Запись без кадров — ошибка, файла нет.
    func stopVideo() async throws -> URL

    /// Запись уже идёт.
    var isRecordingVideo: Bool { get }

    /// Возвращается, когда идущая запись оборвалась сама. Если записи нет — сразу.
    func awaitVideoInterrupted() async
}

/// Разрешения очков в Meta AI — для тех, кто решает по ним.
protocol GlassesPermissions {
    func isGranted(_ permission: GlassesPermission) async -> Bool
}

enum GlassesPermission: String, CaseIterable {
    case camera
    case microphone
}

/// Разрешения очков для звука через поток камеры.
let glassesAudioPermissions: [GlassesPermission] = [.camera, .microphone]

/// Просит разрешения очков в Meta AI: открывает Meta AI, где пользователь их выдаёт. Meta AI просит одно
/// разрешение за раз — спрашиваем друг за другом. true — разрешено всё (или просить было нечего).
protocol GlassesPermissionRequester: AnyObject {
    func request(_ permissions: [GlassesPermission]) async -> Bool
}

extension GlassesPermissions {
    /// Какие из разрешений для звука ещё не выданы. Верно, только пока очки на связи.
    func missingAudioPermissions() async -> [GlassesPermission] {
        var missing: [GlassesPermission] = []
        for permission in glassesAudioPermissions where !(await isGranted(permission)) { missing.append(permission) }
        return missing
    }
}
