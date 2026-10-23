import SwiftUI
import UIKit

/// «Проверка очков» по шагам ([GlassesCheckViewModel]): связь Qanat с очками, кнопка, микрофон, звук в очках и камера,
/// в конце — итог. Открывается сразу после подключения очков и в любое время с экрана «Смарт-очки» и из инструкции
/// по кнопке. [onConnect] — подключить очки заново, когда Qanat к ним не подключён.
struct GlassesCheckScreen: View {
    let viewModel: GlassesCheckViewModel
    let permissions: GlassesPermissions
    let permissionRequester: GlassesPermissionRequester
    let onBack: () -> Void
    let onDone: () -> Void
    let onConnect: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = viewModel.state
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("glasses_check_title"), onBack: onBack)
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if state.stage == .summary {
                        CheckSummary(state: state, onRetry: viewModel.retryStep)
                    } else {
                        StepProgress(state: state)
                        StageCard(state: state)
                    }
                    // В конце прокрутки, а не закреплённой панелью поверх шага.
                    actions(state)
                }
                .padding(.horizontal, 20)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xl)
                .readableWidth()
            }
        }
        .background(palette.background)
        // Шаги идут, только пока экран на виду: иначе кнопка очков так и молчала бы, а микрофон и камера работали бы в фоне.
        .onAppear { if scenePhase == .active { viewModel.onVisible() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.onVisible() } else { viewModel.onHidden() }
        }
        // Закрыли экран — в следующий раз проверка с первого шага.
        .onDisappear {
            viewModel.onHidden()
            viewModel.restart()
        }
        .task(id: state.stage.mismatchGesture) {
            guard state.stage.mismatchGesture != nil else { return }
            try? await Task.sleep(for: .milliseconds(1_600))
            if !Task.isCancelled { viewModel.onMismatchShown() }
        }
    }

    @ViewBuilder
    private func actions(_ state: GlassesCheckUiState) -> some View {
        let stage = state.stage
        VStack(spacing: 6) {
            if stage == .summary {
                PrimaryButton(text: L.t("glasses_check_done"), action: onDone)
                TextAction(text: L.t("glasses_check_again"), action: viewModel.restart)
            } else if state.stagePassed {
                // Пройденный шаг сам уходит дальше.
                EmptyView()
            } else if let failure = stage.failure {
                let fix = failure.fix
                if let fix { PrimaryButton(text: L.t(fix.label)) { apply(fix) } }
                PrimaryButton(
                    text: L.t("glasses_check_retry"),
                    background: fix != nil ? palette.secondaryContainer : nil,
                    foreground: fix != nil ? palette.onSecondaryContainer : nil,
                    action: viewModel.retry
                )
                TextAction(text: L.t("glasses_check_next"), action: viewModel.onNext)
            } else if case .speaker(let playing, _) = stage {
                HStack(spacing: Spacing.sm) {
                    PrimaryButton(text: L.t("glasses_check_speaker_yes")) { viewModel.onSignalHeard(true) }
                    PrimaryButton(
                        text: L.t("glasses_check_speaker_no"),
                        background: palette.secondaryContainer,
                        foreground: palette.onSecondaryContainer
                    ) { viewModel.onSignalHeard(false) }
                }
                if !playing { TextAction(text: L.t("glasses_check_speaker_replay"), action: viewModel.retry) }
                TextAction(text: L.t("glasses_check_skip"), action: viewModel.skip)
            } else {
                TextAction(text: L.t("glasses_check_skip"), action: viewModel.skip)
            }
        }
    }

    /// Выполняет [Fix]; доступ, разрешённый в Meta AI, сразу повторяет шаг.
    private func apply(_ fix: Fix) {
        switch fix {
        // Bluetooth из приложения на iOS не включить — ведём в настройки; включённый Bluetooth шаг связи увидит сам.
        case .enableBluetooth: openURL(URL(string: UIApplication.openSettingsURLString)!)
        case .connect: onConnect()
        case .openMetaAi: openMetaAi(openURL)
        case .allowAudio:
            Task {
                if await permissionRequester.request(await permissions.missingAudioPermissions()) { viewModel.retry() }
            }
        case .allowCamera:
            Task {
                let missing: [GlassesPermission] = await permissions.isGranted(.camera) ? [] : [.camera]
                if await permissionRequester.request(missing) { viewModel.retry() }
            }
        }
    }
}

/// Что можно сделать с причиной неудачи прямо с экрана проверки.
private enum Fix {
    case enableBluetooth, connect, openMetaAi
    /// Звук очков идёт через поток их камеры — микрофону нужны оба доступа.
    case allowAudio
    case allowCamera

    var label: String {
        switch self {
        case .enableBluetooth: "glasses_check_enable_bluetooth"
        case .connect: "glasses_check_connect"
        case .openMetaAi: "registration_open_meta_ai"
        case .allowAudio, .allowCamera: "glasses_check_allow"
        }
    }
}

private extension CheckFailure {
    var fix: Fix? {
        switch self {
        case .link(.bluetoothOff): .enableBluetooth
        case .link(.notRegistered), .link(.notAllowed): .connect
        case .link(.noGlasses), .link(.offline), .link(.glassesUpdate), .link(.glassesAppUpdate),
             .link(.glassesAppUnavailable), .link(.unknown): .openMetaAi
        case .microphone(.noAccess): .allowAudio
        case .camera(.noAccess): .allowCamera
        // Сложенные, снятые, разряженные и перегретые очки, новую версию Qanat и занятую камеру поправит только сам
        // пользователь, остальное — «Повторить».
        default: nil
        }
    }

    var textKey: String {
        switch self {
        case .link(let problem):
            switch problem {
            case .bluetoothOff: "glasses_check_link_bluetooth_off"
            case .notRegistered: "glasses_check_link_not_registered"
            case .noGlasses: "glasses_check_link_no_glasses"
            case .folded: "glasses_check_link_folded"
            case .offline: "glasses_check_link_offline"
            case .qanatUpdate: "glasses_check_link_qanat_update"
            case .glassesUpdate: "glasses_check_link_glasses_update"
            case .takenOff: "glasses_check_link_taken_off"
            case .notAllowed: "glasses_check_link_not_allowed"
            case .glassesAppUpdate: "glasses_check_link_glasses_app_update"
            case .glassesAppUnavailable: "glasses_check_link_glasses_app_unavailable"
            case .lowBattery: "glasses_check_link_low_battery"
            case .overheated: "glasses_check_link_overheated"
            case .unknown: "glasses_check_link_unknown"
            }
        case .buttonNotConnected: "glasses_check_button_not_connected"
        case .microphone(let failure):
            switch failure {
            case .noAccess: "glasses_check_mic_no_access"
            case .notConnected: "glasses_check_mic_not_connected"
            case .busy: "glasses_check_mic_busy"
            case .streamError: "glasses_check_mic_stream"
            case .silent: "glasses_check_mic_silent"
            }
        case .speakerNotHeard: "glasses_check_speaker_not_heard"
        case .camera(let failure):
            switch failure {
            case .noAccess: "glasses_check_camera_no_access"
            case .notConnected: "glasses_check_camera_not_connected"
            case .failed: "glasses_check_camera_failed"
            }
        }
    }
}

private extension CheckStage {
    var mismatchGesture: GlassesGesture? {
        if case .button(_, let mismatch, _) = self { return mismatch }
        return nil
    }

    /// Шаг ждёт очки, а не пользователя: связь, запуск микрофона, снимок.
    var isBusy: Bool {
        switch self {
        case .link, .camera: true
        case .microphone(let listening, _, _): !listening
        case .button, .speaker, .summary: false
        }
    }

    /// Что сейчас происходит на шаге, пока он ни прошёл, ни упал. Шаг «Кнопка» показывает жест ([ButtonPrompt]).
    var promptKey: String {
        switch self {
        case .link: "glasses_check_link_waiting"
        case .microphone(let listening, _, _): listening ? "glasses_check_mic_listening" : "glasses_check_mic_starting"
        case .speaker(let playing, _): playing ? "glasses_check_speaker_playing" : "glasses_check_speaker_question"
        case .camera: "glasses_check_camera_capturing"
        case .button, .summary: ""
        }
    }
}

private extension GlassesCheckStep {
    var icon: String {
        switch self {
        case .link: "antenna.radiowaves.left.and.right"
        case .button: "hand.tap"
        case .microphone: "mic"
        case .speaker: "speaker.wave.2"
        case .camera: "camera"
        }
    }

    var titleKey: String {
        switch self {
        case .link: "glasses_check_step_link"
        case .button: "glasses_check_step_button"
        case .microphone: "glasses_check_step_microphone"
        case .speaker: "glasses_check_step_speaker"
        case .camera: "glasses_check_step_camera"
        }
    }

    var passedKey: String {
        switch self {
        case .link: "glasses_check_link_passed"
        case .button: "glasses_check_button_passed"
        case .microphone: "glasses_check_mic_passed"
        case .speaker: "glasses_check_speaker_passed"
        case .camera: "glasses_check_camera_passed"
        }
    }
}

private extension GlassesGesture {
    var nameKey: String {
        switch self {
        case .singlePress: "glasses_guide_gesture_single"
        case .hold: "glasses_guide_gesture_hold"
        case .doublePress: "glasses_guide_gesture_double"
        case .clickAndHold: "glasses_guide_gesture_click_hold"
        case .triplePress: "glasses_guide_gesture_triple"
        }
    }

    /// Что жест делает, пока не идёт запись или разговор, — как во вкладке «В покое» инструкции (GlassesGuideScreen).
    var actionKey: String {
        switch self {
        case .singlePress: "glasses_guide_action_photo"
        case .hold: "glasses_guide_action_video_start"
        case .clickAndHold: "glasses_guide_action_note_start"
        case .doublePress: "glasses_guide_action_talk_start"
        case .triplePress: "glasses_guide_action_new_chat"
        }
    }

    /// Как сделать жест проверки; простого удержания в ней нет — его только узнают, когда нажали вместо нужного.
    var howKey: String? {
        switch self {
        case .singlePress: "glasses_check_how_single"
        case .clickAndHold: "glasses_check_how_click_hold"
        case .doublePress: "glasses_check_how_double"
        case .triplePress: "glasses_check_how_triple"
        case .hold: nil
        }
    }
}

private enum StepMark { case passed, failed, skipped, active, pending }

private extension GlassesCheckUiState {
    func mark(of step: GlassesCheckStep) -> StepMark {
        switch results[step] {
        case .passed: return .passed
        case .failed: return .failed
        case .skipped: return .skipped
        case nil:
            if stage.step != step { return .pending }
            return stage.failure != nil ? .failed : .active
        }
    }
}

private let badgeSize: CGFloat = 56
private let markerSize: CGFloat = 28
private let markerGap: CGFloat = 14

/// «Шаг 2 из 5» и метки всех шагов: подробно каждый шаг — в итоге.
private struct StepProgress: View {
    let state: GlassesCheckUiState
    @Environment(\.palette) private var palette

    var body: some View {
        if let step = state.stage.step {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(L.t("glasses_check_progress", step.rawValue + 1, GlassesCheckStep.allCases.count))
                    .textStyle(Typography.labelLarge)
                    .foregroundStyle(palette.onSurfaceVariant)
                HStack(spacing: Spacing.sm) {
                    ForEach(GlassesCheckStep.allCases, id: \.self) { StepMarker(mark: state.mark(of: $0), size: 20) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StageCard: View {
    let state: GlassesCheckUiState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Spacing.sm) {
            StageContent(state: state)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity)
        .id(state.stage.step)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 40)), removal: .opacity))
        .animation(.easeOut(duration: 0.22), value: state.stage.step)
        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

private struct StageContent: View {
    let state: GlassesCheckUiState
    @Environment(\.palette) private var palette
    @Environment(\.windowLayout) private var layout

    var body: some View {
        let stage = state.stage
        if let step = stage.step {
            let passed = state.stagePassed
            let failure = stage.failure
            Group {
                if passed {
                    StatusBadge(kind: .passed)
                } else if failure != nil {
                    StatusBadge(kind: .failed)
                } else if case .button = stage {
                    // Телефон боком — рисунок меньше, чтобы под ним было видно, какой жест повторить.
                    GlassesTempleArt().frame(width: layout.compactHeight ? 154 : 220, height: layout.compactHeight ? 70 : 100)
                } else if stage.isBusy {
                    ProgressView().controlSize(.large).tint(palette.primary).frame(width: badgeSize, height: badgeSize)
                } else {
                    StatusBadge(kind: .step(step.icon))
                }
            }
            Text(L.t(step.titleKey))
                .textStyle(Typography.titleLarge)
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.center)
            if passed {
                CheckMessage(text: L.t(step.passedKey))
            } else if let failure {
                CheckMessage(text: L.t(failure.textKey), color: palette.error)
            } else if case .button = stage {
                ButtonPrompt(stage: stage)
            } else {
                CheckMessage(text: L.t(stage.promptKey))
            }
            switch stage {
            case .button(let done, _, _):
                GestureList(done: done)
            case .microphone(let listening, let level, _) where listening && !passed && failure == nil:
                LevelBar(level: level)
            case .camera:
                if let photo = state.photo {
                    CheckPhoto(data: photo).frame(width: 150).aspectRatio(3 / 4, contentMode: .fit).padding(.top, Spacing.sm)
                }
            default:
                EmptyView()
            }
        }
    }
}

private struct CheckMessage: View {
    let text: String
    var color: Color?
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).textStyle(Typography.bodyMedium).foregroundStyle(color ?? palette.secondary).multilineTextAlignment(.center)
    }
}

/// Какой жест повторить и как, а после неверного — какой жест получился.
private struct ButtonPrompt: View {
    let stage: CheckStage
    @Environment(\.palette) private var palette

    var body: some View {
        if let expected = stage.expectedGesture {
            Text(L.t("glasses_check_button_intro"))
                .textStyle(Typography.bodySmall)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text(L.t(expected.nameKey))
                .textStyle(Typography.titleMedium)
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.center)
                .padding(.top, Spacing.xs)
            if let how = expected.howKey { CheckMessage(text: L.t(how)) }
            CheckMessage(text: L.t("glasses_check_button_meaning", L.t(expected.actionKey)))
            // Какой жест получился вместо нужного; уходящая подсказка гаснет со своим текстом, а не пустой.
            ZStack {
                if let gesture = stage.mismatchGesture {
                    Text(L.t("glasses_check_button_mismatch", L.t(gesture.nameKey)))
                        .textStyle(Typography.bodySmall)
                        .foregroundStyle(palette.error)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: stage.mismatchGesture)
        }
    }
}

private struct GestureList: View {
    let done: Int
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(checkGestures.indices, id: \.self) { index in
                let gesture = checkGestures[index]
                let mark: StepMark = index < done ? .passed : (index == done ? .active : .pending)
                HStack(spacing: Spacing.md) {
                    StepMarker(mark: mark, size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L.t(gesture.nameKey))
                            .textStyle(Typography.bodyMedium)
                            .foregroundStyle(mark == .pending ? palette.secondary : palette.onSurface)
                        Text(L.t(gesture.actionKey)).textStyle(Typography.bodySmall).foregroundStyle(palette.secondary)
                    }
                }
                .frame(minHeight: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.sm)
    }
}

/// Громкость микрофона очков; черта — с какой громкости звук считается речью.
private struct LevelBar: View {
    let level: Float
    @Environment(\.palette) private var palette

    var body: some View {
        let speechMark = CGFloat(micLevel(speechPeakAmplitude))
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceVariant)
                Capsule()
                    .fill(CGFloat(level) > speechMark ? palette.tones.connected : palette.primary)
                    .frame(width: width * CGFloat(level))
                    .animation(.linear(duration: 0.09), value: level)
                Rectangle().fill(palette.outline).frame(width: 2).offset(x: width * speechMark - 1)
            }
        }
        .frame(height: 12)
        .padding(.top, Spacing.sm)
        .accessibilityValue(Text("\(Int(level * 100))%"))
    }
}

/// Превью снимка с очков: декодируем вне главного потока и уменьшенным.
private struct CheckPhoto: View {
    let data: Data
    @State private var image: UIImage?
    @Environment(\.palette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.surfaceContainerHigh)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: data) {
                let data = data
                image = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 480, height: 640)) }.value
            }
    }
}

private struct CheckSummary: View {
    let state: GlassesCheckUiState
    let onRetry: (GlassesCheckStep) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let results = Array(state.results.values)
        let (badge, text): (BadgeKind, String) = if results.contains(where: { if case .failed = $0 { true } else { false } }) {
            (.failed, "glasses_check_summary_problems")
        } else if results.allSatisfy({ $0 == .passed }) {
            (.passed, "glasses_check_summary_ok")
        } else {
            (.skipped, "glasses_check_summary_partial")
        }
        VStack(spacing: Spacing.xs) {
            StatusBadge(kind: badge)
            Text(L.t("glasses_check_summary_title"))
                .textStyle(Typography.titleLarge)
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.center)
                .padding(.top, Spacing.sm)
            CheckMessage(text: L.t(text))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.md)
        VStack(spacing: 0) {
            ForEach(GlassesCheckStep.allCases, id: \.self) { step in
                if step.rawValue > 0 {
                    Rectangle().fill(palette.outlineVariant).frame(height: 1).padding(.leading, Spacing.lg + markerSize + markerGap)
                }
                SummaryRow(
                    step: step,
                    result: state.results[step],
                    mark: state.mark(of: step),
                    photo: step == .camera ? state.photo : nil,
                    onRetry: { onRetry(step) }
                )
            }
        }
        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

private struct SummaryRow: View {
    let step: GlassesCheckStep
    let result: CheckResult?
    let mark: StepMark
    let photo: Data?
    let onRetry: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: markerGap) {
            StepMarker(mark: mark)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t(step.titleKey)).textStyle(Typography.bodyMedium.weight(.medium)).foregroundStyle(palette.onSurface)
                Text(resultText).textStyle(Typography.bodySmall).foregroundStyle(isFailed ? palette.error : palette.onSurfaceVariant)
                if result != .passed {
                    Button(action: onRetry) {
                        Text(L.t("glasses_check_retry")).textStyle(Typography.labelLarge).foregroundStyle(palette.primary)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let photo { CheckPhoto(data: photo).frame(width: 48, height: 48) }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 60)
    }

    private var isFailed: Bool {
        if case .failed = result { return true }
        return false
    }

    private var resultText: String {
        switch result {
        case .passed: L.t(step.passedKey)
        case .failed(let failure): L.t(failure.textKey)
        case .skipped, nil: L.t("glasses_check_skipped")
        }
    }
}

/// Второстепенное действие — текстом во всю ширину; minHeight, а не height: крупным шрифтом строка выше 44pt.
private struct TextAction: View {
    let text: String
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Text(text)
                .textStyle(Typography.bodyMedium)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum BadgeKind { case passed, failed, skipped, step(String) }

/// Круг над шагом: прошёл, не прошёл, пропущен — или значок самого шага.
private struct StatusBadge: View {
    let kind: BadgeKind
    @Environment(\.palette) private var palette

    var body: some View {
        let (background, tint, symbol): (Color, Color, String) = switch kind {
        case .passed: (palette.tones.connected, palette.onPrimary, "checkmark")
        case .failed: (palette.errorContainer, palette.onErrorContainer, "exclamationmark")
        case .skipped: (palette.surfaceVariant, palette.onSurfaceVariant, "minus")
        case .step(let icon): (palette.primaryContainer, palette.onPrimaryContainer, icon)
        }
        Circle()
            .fill(background)
            .frame(width: badgeSize, height: badgeSize)
            .overlay { Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(tint) }
            .accessibilityHidden(true)
    }
}

private struct StepMarker: View {
    let mark: StepMark
    var size: CGFloat = markerSize
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            switch mark {
            case .passed:
                Circle().fill(palette.tones.connected).overlay { symbol("checkmark", palette.onPrimary) }
            case .failed:
                Circle().fill(palette.error).overlay { symbol("xmark", palette.onError) }
            case .skipped:
                Circle().strokeBorder(palette.outline, lineWidth: 2).overlay { symbol("minus", palette.onSurfaceVariant) }
            case .active:
                ActiveRing(lineWidth: size < markerSize ? 2 : 3)
            case .pending:
                Circle().strokeBorder(palette.outline, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(.easeOut(duration: 0.2), value: mark)
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(tint)
    }
}

/// Крутящееся кольцо идущего шага — как неопределённый CircularProgressIndicator.
private struct ActiveRing: View {
    let lineWidth: CGFloat
    @State private var spinning = false
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Circle().stroke(palette.primaryContainer, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(palette.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
        }
        .padding(lineWidth / 2)
        .onAppear { spinning = true }
    }
}
