import Foundation

/// Звук микрофона очков через поток камеры Meta SDK — единственный путь к их микрофону: Bluetooth HFP приложение
/// не использует. Пока он идёт, на очках мигает индикатор съёмки: без потока камеры SDK звук не отдаёт.
protocol GlassesAudioCapture: AnyObject {
    /// Включает камеру очков с PCM 16 кГц моно и видео под [use] и ждёт, пока поток пойдёт.
    /// Отмена во время запуска выключает камеру. Не бросает, кроме отмены.
    func startAudio(_ use: GlassesAudioUse) async -> GlassesAudioStart
}

/// Для чего нужен звук очков: от этого зависит задержка звука.
enum GlassesAudioUse {
    /// Голосовое в файл: порядок кадров восстанавливается с запасом — задержка файлу не мешает.
    case note
    /// Живой разговор: порядок кадров — с наименьшей задержкой.
    case conversation

    /// Кадров держим, чтобы вернуть порядок по времени: 4 кадра — около 256 мс; в разговоре — один.
    var reorderWindow: Int { self == .note ? 4 : 1 }
}

enum GlassesAudioStart {
    /// Поток идёт: звук — [GlassesAudio.frames]; выключить — [GlassesAudio.stop].
    case started(GlassesAudio)
    case failed(GlassesAudioError)
}

enum GlassesAudioError: Error, Equatable {
    /// Очков нет на связи или Qanat не подключён к ним.
    case notConnected
    /// В Meta AI не разрешены камера или микрофон очков.
    case noPermission
    /// Камера очков уже занята без звука: идёт запись видео или снимок.
    case busy
    /// Очки отклонили поток, он не пошёл вовремя или оборвался.
    case streamError
}

/// Идущий поток звука с очков.
protocol GlassesAudio: AnyObject {
    /// uptimeMs перед запуском потока — от него считают задержку первого звука.
    var startedAtMs: Int64 { get }

    /// Кадры PCM s16le в порядке времени и без потерь: всё полученное копится, пока его не заберут. Читать одному.
    /// Кончается после [stop] или когда поток оборвался либо замолчал — тогда [error] не nil.
    var frames: AsyncQueue<GlassesAudioFrame> { get }

    /// Почему поток кончился сам; nil — идёт или его остановили [stop].
    var error: GlassesAudioError? { get }

    /// JPEG-кадры с камеры этого же потока, не чаще раза в [intervalMs].
    func liveFrames(intervalMs: Int64) -> AsyncStream<Data>

    /// Отписывается от звука, затем выключает камеру (так требует SDK). Повторный вызов ничего не делает.
    func stop() async
}

/// Кадр звука: время по часам потока, PCM s16le моно, когда он пришёл (uptimeMs) и его номер по порядку прихода.
struct GlassesAudioFrame {
    let presentationTimeUs: Int64
    let pcm: Data
    let arrivedAtMs: Int64
    let arrivalIndex: Int

    var samples: Int { pcm.count / 2 }
}

let glassesAudioSampleRate = 16_000

/// Восстанавливает порядок кадров по времени: держит до [window] последних кадров и отдаёт самый ранний,
/// когда их больше. Кадр, опоздавший сильнее окна, отдаётся сразу же — потерять звук хуже, чем переставить кадр.
struct PcmReorderBuffer {
    let window: Int
    private var held: [GlassesAudioFrame] = []

    init(window: Int) {
        precondition(window >= 0, "Окно не может быть отрицательным: \(window)")
        self.window = window
    }

    /// Принимает кадр и возвращает те, что пора отдать, — по времени.
    mutating func push(_ frame: GlassesAudioFrame) -> [GlassesAudioFrame] {
        held.append(frame)
        held.sort { ($0.presentationTimeUs, $0.arrivalIndex) < ($1.presentationTimeUs, $1.arrivalIndex) }
        var out: [GlassesAudioFrame] = []
        while held.count > window { out.append(held.removeFirst()) }
        return out
    }

    /// Остаток по времени — когда кадров больше не будет.
    mutating func drain() -> [GlassesAudioFrame] {
        defer { held.removeAll() }
        return held
    }
}

/// Просьба разрешить камеру и микрофон очков в Meta AI, когда голосовое или разговор с очков не начались из-за того,
/// что их не разрешили. Просим один раз за запуск приложения и только при открытом экране.
@Observable
final class GlassesAudioPermissionPrompt {
    private var asked = false
    /// Экран слушает, пока виден; true — пора спросить.
    var pending = false
    var screenVisible = false

    func request() {
        DispatchQueue.main.async {
            guard self.screenVisible, !self.asked else { return }
            self.asked = true
            self.pending = true
        }
    }
}
