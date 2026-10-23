import AVFoundation
import SwiftUI
import WebKit

/// Экран голоса только показывает [HandsFreeVoice]: команды с очков работают и без него.
struct VoiceScreen: View {
    let voice: HandsFreeVoice
    let glasses: GlassesControls
    let glassesPermissions: GlassesPermissions
    let permissionRequester: GlassesPermissionRequester
    let onClose: () -> Void
    let onConnectGlasses: () -> Void
    /// Экран открыли из уведомления о сбое команды с очков — что в нём выбрали.
    @Binding var noticeAction: VoiceNoticeAction?

    @State private var isGlassesRegistered = false
    @State private var isGlassesConnected = false
    @State private var micDenied = false
    @Environment(\.windowLayout) private var layout

    var body: some View {
        content
            .qanatVoiceTheme()
            .background(Palette.voice.background.ignoresSafeArea())
            .onReceive(glasses.isRegistered.receive(on: DispatchQueue.main)) { isGlassesRegistered = $0 }
            .onReceive(glasses.deviceInfo.receive(on: DispatchQueue.main)) { isGlassesConnected = $0?.isConnected == true }
            // Пока экран на виду, сбой команды с очков он покажет сам — уведомление о нём не нужно.
            .onAppear { voice.voiceScreenVisible = true }
            .onDisappear { voice.voiceScreenVisible = false }
            .task(id: noticeAction) {
                guard let action = noticeAction else { return }
                noticeAction = nil
                switch action {
                case .allowGlassesMicrophone: await allowGlassesMicrophone()
                case .usePhoneMicrophone: await usePhoneMicrophone()
                case .open: break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        let state = voice.state
        VStack(spacing: 0) {
            topBar
            if layout.compactHeight && layout.landscape {
                // Телефон боком: шар слева на всю высоту, справа — что происходит и кнопки.
                HStack(spacing: 24) {
                    orb(state).padding(.bottom, 12)
                    GeometryReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                VoiceStatus(state: state, micDenied: micDenied)
                                Spacer(minLength: 0)
                                controls(state).padding(.top, 12)
                            }
                            .frame(minHeight: proxy.size.height)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .padding(.horizontal, 28)
            } else {
                GeometryReader { proxy in
                    // Как в макете, до 330pt, но тексту под ним остаётся не меньше 120pt.
                    let orbArea = min(max(proxy.size.height - 120, 0), 330)
                    VStack(spacing: 0) {
                        orb(state).frame(height: orbArea)
                        // Длинный ответ или крупный шрифт не наезжают на кнопки — текст прокручивается.
                        ScrollView { VoiceStatus(state: state, micDenied: micDenied) }
                    }
                }
                .padding(.horizontal, 28)
                .readableWidth()
                controls(state)
                    .padding(.horizontal, 28)
                    .padding(.bottom, layout.compactHeight ? 12 : 40)
                    .readableWidth()
            }
        }
    }

    private var topBar: some View {
        HStack {
            if isGlassesConnected {
                HStack(spacing: 8) {
                    GlassesIcon(tint: Palette.voice.onSurfaceVariant).frame(width: 18, height: 18)
                    Text(L.t("voice_audio_route_glasses")).textStyle(Typography.bodySmall).foregroundStyle(Palette.voice.onSurfaceVariant)
                }
            }
            Spacer()
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").font(.system(size: 15))
                    Text(L.t("voice_back_to_chat")).textStyle(Typography.bodyMedium.size(14))
                }
                .foregroundStyle(Palette.voice.onSurface)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Palette.voice.surfaceContainer, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: layout.topBarHeight)
    }

    /// Шар по размеру места: не больше 240pt и с полями вокруг, как в макете.
    private func orb(_ state: VoiceUiState) -> some View {
        GeometryReader { proxy in
            let size = min(240, proxy.size.width, proxy.size.height * 240 / 330)
            VoiceOrb(state: state)
                .frame(width: size, height: size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func controls(_ state: VoiceUiState) -> some View {
        let inCall = state.isConversation
        let active = inCall || state == .recordingNote || state == .sendingNote || state == .answeringNote
        let palette = Palette.voice
        return VStack(spacing: 16) {
            if active {
                // Микрофон выключается только в разговоре — у голосового и ответа на него кнопке нечего делать.
                HStack {
                    if inCall {
                        Button(action: voice.toggleMute) {
                            Image(systemName: voice.muted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(palette.onSurface)
                                .frame(width: 64, height: 64)
                                .background(palette.surfaceContainer, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L.t(voice.muted ? "voice_unmute" : "voice_mute"))
                        Spacer()
                    }
                    Button(action: toggle) {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(palette.onError)
                            .frame(width: 64, height: 64)
                            .background(palette.error, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.t("voice_stop"))
                }
            } else {
                // Микрофон очков не пошёл: разговор можно продолжить с телефона, а сам микрофон — разрешить в Meta AI.
                if case .error(_, let help) = state, let help {
                    if help.canUsePhone {
                        PrimaryButton(text: L.t("voice_glasses_mic_use_phone")) { Task { await usePhoneMicrophone() } }
                    }
                    if help.askPermission {
                        outlinedButton(L.t("voice_glasses_mic_allow")) { Task { await allowGlassesMicrophone() } }
                    }
                }
                Button(action: toggle) {
                    Text(L.t("voice_start"))
                        .textStyle(Typography.titleMedium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(palette.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(palette.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                if !isGlassesRegistered {
                    outlinedButton(L.t("voice_glasses_connect"), action: onConnectGlasses)
                }
            }
            let hints = hintKeys(state)
            if !hints.isEmpty {
                VStack(spacing: 4) {
                    ForEach(hints, id: \.self) { key in
                        Text(L.t(key))
                            .textStyle(Typography.labelMedium.weight(.regular))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private func outlinedButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .textStyle(Typography.labelLarge)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.voice.onSurface)
                .frame(maxWidth: .infinity, minHeight: 40)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Palette.voice.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Перебить голосом можно только Каната в разговоре; кнопка очков — что она сейчас делает.
    private func hintKeys(_ state: VoiceUiState) -> [String] {
        var hints: [String] = []
        if case .talking = state { hints.append("voice_interrupt_hint") }
        if isGlassesRegistered {
            switch state {
            case .idle, .error: hints.append("voice_glasses_hint")
            case .connecting, .talking: hints.append("voice_glasses_hint_call")
            case .recordingNote: hints.append("voice_glasses_hint_note")
            case .answeringNote: hints.append("voice_glasses_hint_answer")
            case .sendingNote: break
            }
        }
        return hints
    }

    /// Разговор с экрана — только с разрешением на микрофон.
    private func toggle() {
        Task {
            if voice.state.isConversation || voice.state == .recordingNote || voice.state == .answeringNote || voice.state == .sendingNote {
                voice.toggleConversation()
                return
            }
            let granted = await AVAudioApplication.requestRecordPermission()
            micDenied = !granted
            if granted { voice.toggleConversation() }
        }
    }

    private func usePhoneMicrophone() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        micDenied = !granted
        if granted { voice.continueWithPhoneMicrophone() }
    }

    private func allowGlassesMicrophone() async {
        _ = await permissionRequester.request(await glassesPermissions.missingAudioPermissions())
    }
}

/// Что сейчас происходит: состояние крупно, услышанная фраза и пояснение.
private struct VoiceStatus: View {
    let state: VoiceUiState
    let micDenied: Bool

    var body: some View {
        let palette = Palette.voice
        VStack(spacing: 0) {
            Text(statusLabel.uppercased(with: LanguageSettings.shared.language.locale))
                .textStyle(BrandText.voiceStatus)
                .foregroundStyle(palette.primary)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 18)
            if case .talking(_, let heard?, _) = state {
                Text(heard.text)
                    .textStyle(Typography.bodyMedium.size(15, lineHeight: 22))
                    .foregroundStyle(palette.onSurfaceVariant.opacity(heard.final ? 1 : 0.6))
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 8)
            }
            Text(subtitle)
                .textStyle(Typography.bodyLarge.size(20, lineHeight: 29))
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusLabel: String {
        switch state {
        case .idle: L.t("voice_status_idle")
        case .connecting: L.t("voice_status_connecting")
        case .talking: L.t("voice_status_talking")
        case .recordingNote: L.t("voice_status_recording")
        case .sendingNote: L.t("voice_status_sending")
        case .answeringNote: L.t("voice_status_answering")
        case .error: L.t("voice_status_error")
        }
    }

    private var subtitle: String {
        if micDenied { return L.t("voice_mic_denied") }
        switch state {
        case .error(let key, _): return L.t(key)
        case .talking(let subtitle, _, _): return subtitle ?? L.t("voice_talking")
        case .recordingNote: return L.t("voice_recording_note")
        case .sendingNote: return L.t("voice_sending_note")
        case .answeringNote: return L.t("voice_answering_note")
        default: return L.t("voice_idle")
        }
    }
}

/// Шар Каната (qanat_orb.html) — тот же рисунок, что на плитке бота в Zoom. Громкость звука в шар не передаём,
/// поэтому край шара рисует ровную «речь».
struct VoiceOrb: UIViewRepresentable {
    let state: VoiceUiState

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        if let file = Bundle.main.url(forResource: "qanat_orb", withExtension: "html") {
            var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "state", value: orbState)]
            view.loadFileURL(components.url!, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        context.coordinator.shown = orbState
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != orbState else { return }
        context.coordinator.shown = orbState
        view.evaluateJavaScript("qanat.state('\(orbState)')")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown = ""
    }

    private var orbState: String {
        switch state {
        case .idle: "ended"
        case .connecting: "connecting"
        case .talking, .recordingNote: "listening"
        case .sendingNote: "thinking"
        case .answeringNote: "speaking"
        case .error: "error"
        }
    }
}

/// Что сделать, открыв Qanat из уведомления о сбое команды с очков: экран голоса откроется в любом случае.
enum VoiceNoticeAction: String {
    case open
    case allowGlassesMicrophone = "allow_glasses_microphone"
    case usePhoneMicrophone = "use_phone_microphone"
}
