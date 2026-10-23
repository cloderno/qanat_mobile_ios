import Foundation
import Observation
import UIKit

/// Фоновая работа на всё время, пока пользователь авторизован, — и при заблокированном экране (фоновый режим audio).
/// На Android её держит VoiceService: кнопка очков, съёмка с очков, сигнал связи, уведомления о сбоях и о Meta AI.
@MainActor
final class SignedInSession {
    private let container: AppContainer
    private var tasks: [Task<Void, Never>] = []

    init(container: AppContainer) { self.container = container }

    func start() {
        guard tasks.isEmpty else { return }
        let container = container
        let voice = container.voice
        let capture = GlassesCapture(
            glasses: container.glasses,
            camera: container.glasses,
            repository: container.media,
            signals: container.signals,
            photos: container.photos,
            videos: container.videos,
            voice: voice
        )
        let linkSignal = GlassesLinkSignal(link: container.glasses, repository: container.voiceRepository, voice: voice)
        let metaAiNotice = MetaAiUpdateNotice(glasses: container.glasses, link: container.glasses)
        tasks = [
            Task { await voice.listenToGlasses() },
            Task { await capture.run() },
            Task { await linkSignal.run() },
            Task { await metaAiNotice.run() },
            // Команды с очков идут и при заблокированном экране: о сбое, кроме сигнала, говорит уведомление.
            Task { await Self.showFailureNotices(voice) },
        ]
        log.info("Сессия запущена")
    }

    /// Пользователь вышел: команда прерывается, а следующий вход начнётся с нового чата.
    func stop() {
        guard !tasks.isEmpty else { return }
        tasks.forEach { $0.cancel() }
        tasks = []
        container.voice.reset()
        VoiceFailureNotification.cancel()
        log.info("Сессия остановлена")
    }

    private static func showFailureNotices(_ voice: HandsFreeVoice) async {
        var shown = false
        while !Task.isCancelled {
            let (notice, isError) = await nextChange { (voice.failureNotice, voice.state.isError) }
            if let notice {
                voice.failureNotice = nil
                shown = true
                VoiceFailureNotification.show(notice)
            } else if shown, !isError {
                // Ошибку увидели или начали новую команду — уведомление о сбое больше не о чём.
                shown = false
                VoiceFailureNotification.cancel()
            }
        }
    }
}

/// Ждёт, пока изменится что-то из прочитанного в [read] (@Observable), и возвращает новое значение.
@MainActor
func nextChange<T>(_ read: @escaping @MainActor () -> T) async -> T {
    await withCheckedContinuation { continuation in
        withObservationTracking {
            _ = read()
        } onChange: {
            Task { @MainActor in continuation.resume(returning: read()) }
        }
    }
}

private extension VoiceUiState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

private let log = Log("SignedInSession")
