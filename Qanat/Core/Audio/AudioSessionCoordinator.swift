import AVFoundation

/// Одна аудиосессия iOS на всё приложение: голосовое, проигрывание, разговор с Канатом и звук очков просят её
/// под свою задачу. Пока занят хоть кто-то, сессия активна; режим — самого требовательного (разговор > голосовое >
/// проигрывание). На Android то же решают AudioManager.mode и атрибуты потоков.
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    enum Use: Int, Comparable {
        /// Голосовой ответ, озвучка, сигналы — только вывод.
        case playback
        /// Голосовое с микрофона телефона.
        case voiceNote
        /// Живой разговор: микрофон и динамик одновременно, с эхоподавлением.
        case conversation

        static func < (lhs: Use, rhs: Use) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let lock = NSLock()
    private var users: [Use: Int] = [:]

    private init() {}

    /// Занимает сессию под [use]. Бросает, если система не дала сессию (например, идёт звонок).
    func activate(_ use: Use) throws {
        try lock.withLock {
            users[use, default: 0] += 1
            do {
                try apply()
            } catch {
                users[use, default: 1] -= 1
                throw error
            }
        }
    }

    /// Освобождает сессию, занятую [activate]; последний освободивший её выключает.
    func deactivate(_ use: Use) {
        lock.withLock {
            guard let count = users[use], count > 0 else { return }
            users[use] = count - 1
            if users.values.allSatisfy({ $0 == 0 }) {
                // Другие приложения (музыка) снова звучат громко.
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } else {
                try? apply()
            }
        }
    }

    var isConversation: Bool { lock.withLock { (users[.conversation] ?? 0) > 0 } }

    private func apply() throws {
        let session = AVAudioSession.sharedInstance()
        let top = users.filter { $0.value > 0 }.keys.max() ?? .playback
        switch top {
        case .conversation:
            // voiceChat — эхоподавление и шумоподавление телефона; Bluetooth — гарнитура и очки как HFP.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        case .voiceNote:
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true)
    }
}
