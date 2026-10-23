import AVFoundation
import SwiftUI

/// Проба микрофона очков для разработчиков: строка в настройках, пока очки подключены.
enum MicProbeUiState: Equatable {
    case idle
    /// [progress] от 0 до 1 — сколько из [probeDurationSeconds] прошло с нажатия; дальше ждём, пока очки отдадут поток.
    case running(progress: Double)
    case done(MicProbeResult)
}

@MainActor
@Observable
final class GlassesMicProbeViewModel {
    private(set) var state: MicProbeUiState = .idle

    @ObservationIgnored private let audio: GlassesAudioCapture

    static let probeDurationSeconds: Double = 10
    private static let tick: Double = 0.2

    init(audio: GlassesAudioCapture) { self.audio = audio }

    /// Пишет запись пробы в новый файл.
    func run() {
        if case .running = state { return }
        state = .running(progress: 0)
        Task {
            let outputURL = newProbeFile()
            let ticker = Task {
                var elapsed = 0.0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.tick))
                    elapsed += Self.tick
                    if case .running = state { state = .running(progress: min(elapsed / Self.probeDurationSeconds, 1)) }
                }
            }
            let result = await probeGlassesMicrophone(audio, durationSeconds: Self.probeDurationSeconds, outputURL: outputURL)
            ticker.cancel()
            state = .done(result)
        }
    }

    /// Камеру или микрофон очков не разрешили в Meta AI — пробу не начинаем.
    func onPermissionDenied() {
        if case .running = state { return }
        state = .done(.failed(.noPermission))
    }
}

/// Новый файл для записи пробы. У каждой пробы свой файл: отправленную запись получатель читает позже,
/// и перезапись под ним отправила бы обрывок. Поэтому прошлую запись оставляем, а более старые удаляем.
private func newProbeFile() -> URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("glasses_mic", isDirectory: true)
    let old = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    old.filter { $0.lastPathComponent.hasPrefix("probe") && $0.pathExtension == "wav" }
        .sorted { modified($0) > modified($1) }
        .dropFirst(1)
        .forEach { try? FileManager.default.removeItem(at: $0) }
    return dir.appendingPathComponent("probe-\(Int64(Date().timeIntervalSince1970 * 1000)).wav")
}

private func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}

/// «Проба микрофона очков (DAT)»: 10 секунд звука через поток камеры очков, замеры, прослушать и поделиться WAV.
/// Для разработчиков (только debug-сборка) — проверить, годится ли этот звук для голосовых. [connected] — очки сейчас на связи.
struct GlassesMicProbeRow: View {
    @State var viewModel: GlassesMicProbeViewModel
    let connected: Bool
    let permissions: GlassesPermissions
    let permissionRequester: GlassesPermissionRequester

    @Environment(\.palette) private var palette

    var body: some View {
        let running: Bool = if case .running = viewModel.state { true } else { false }
        Button(action: start) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("glasses_mic_probe_title")).textStyle(Typography.bodyLarge.weight(.medium)).foregroundStyle(palette.onSurface)
                switch viewModel.state {
                case .idle:
                    ProbeHint(text: L.t("glasses_mic_probe_hint"))
                case .running(let progress):
                    ProbeHint(text: L.t("glasses_mic_probe_running"))
                    if progress < 1 {
                        ProgressView(value: progress).tint(palette.primary)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(palette.primary)
                    }
                case .done(let result):
                    ProbeResultView(result: result)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(running)
    }

    private func start() {
        Task {
            // Пока очки не на связи, SDK и про выданное разрешение отвечает «нет» — тогда не зовём Meta AI зря,
            // а запускаем пробу: она дождётся очков или сообщит, что их нет.
            let missing = connected ? await permissions.missingAudioPermissions() : []
            if await permissionRequester.request(missing) { viewModel.run() } else { viewModel.onPermissionDenied() }
        }
    }
}

private struct ProbeHint: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
    }
}

private struct ProbeResultView: View {
    let result: MicProbeResult
    @State private var player: AVAudioPlayer?
    @State private var playerDelegate = ProbePlayerDelegate()
    @Environment(\.palette) private var palette

    var body: some View {
        if let error = result.error {
            Text(L.t(error.messageKey)).textStyle(Typography.bodyMedium).foregroundStyle(palette.error)
        }
        if let latency = result.firstFrameLatencyMs { ProbeHint(text: L.t("glasses_mic_probe_latency", Int(latency))) }
        if result.frames > 0 {
            ProbeHint(text: L.t("glasses_mic_probe_frames", result.frames, result.totalSamples, Double(result.durationMs) / 1000))
            ProbeHint(text: L.t("glasses_mic_probe_gaps", result.gaps.count, Int(result.gaps.maxGapMs)))
            ProbeHint(text: L.t("glasses_mic_probe_order", result.gaps.outOfOrder, result.gaps.overlaps))
        }
        ProbeHint(text: L.t("glasses_mic_probe_again"))
        if let url = result.wavURL, result.frames > 0 {
            HStack(spacing: 8) {
                Button(L.t(player == nil ? "glasses_mic_probe_play" : "glasses_mic_probe_stop")) { toggle(url) }
                ShareLink(item: url) { Text(L.t("glasses_mic_probe_share")) }
            }
            .textStyle(Typography.labelLarge)
            .foregroundStyle(palette.primary)
            .onDisappear { player?.stop() }
        }
    }

    private func toggle(_ url: URL) {
        if let player {
            player.stop()
            self.player = nil
            return
        }
        do {
            try AudioSessionCoordinator.shared.activate(.playback)
            let started = try AVAudioPlayer(contentsOf: url)
            playerDelegate.onFinish = { player = nil }
            started.delegate = playerDelegate
            started.play()
            player = started
        } catch {
            // Файл стёрли вместе с кешем или WAV битый.
            Log("GlassesMicProbe").warning("Запись пробы не воспроизводится: \(error)")
        }
    }
}

private final class ProbePlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}

private extension MicProbeError {
    var messageKey: String {
        switch self {
        case .notConnected: "glasses_mic_probe_error_not_connected"
        case .noPermission: "glasses_mic_probe_error_permission"
        case .cameraBusy: "glasses_mic_probe_error_busy"
        case .streamError: "glasses_mic_probe_error_stream"
        case .noAudio: "glasses_mic_probe_error_no_audio"
        case .fileError: "glasses_mic_probe_error_file"
        }
    }
}
