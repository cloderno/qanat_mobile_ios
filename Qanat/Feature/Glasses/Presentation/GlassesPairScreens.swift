import AVFoundation
import CoreBluetooth
import SwiftUI
import UserNotifications

/// Очки ещё не подключены: что даст подключение и как оно пройдёт — прежде чем просить разрешения и уводить в Meta AI.
struct GlassesEmptyScreen: View {
    let onClose: () -> Void
    let onRegistrationStarted: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.windowLayout) private var layout

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("glasses_title"), onBack: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // Телефон боком — рисунок ниже: иначе он один занимал бы весь экран.
                    GlassesDimmedArt()
                        .frame(width: 250, height: 92)
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.compactHeight ? 130 : 210)
                        .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: Radius.extraLarge, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.t("glasses_empty_title")).textStyle(BrandText.greeting.size(24, lineHeight: 29)).foregroundStyle(palette.onSurface)
                        Text(L.t("glasses_empty_text")).textStyle(Typography.bodyLarge).foregroundStyle(palette.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        let steps = ["glasses_empty_step_1", "glasses_onboarding_empty_step_2", "glasses_onboarding_empty_step_3"]
                        ForEach(steps.indices, id: \.self) { NumberedStep(number: $0 + 1, text: L.t(steps[$0])) }
                    }
                    MetaAiFooter(actionText: L.t("glasses_connect_via_meta"), action: onRegistrationStarted, actionIcon: nil, dismissText: L.t("glasses_empty_later"), onDismiss: onClose)
                }
                .padding(.horizontal, 20)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.lg)
                .readableWidth()
            }
        }
        .background(palette.background)
    }
}

struct NumberedStep: View {
    let number: Int
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .textStyle(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(palette.inverseOnSurface)
                .frame(width: 28, height: 28)
                .background(palette.inverseSurface, in: Circle())
            Text(text).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurface).padding(.top, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Конец экранов подключения очков: кнопка — следующий шаг, текстовая ссылка под ней — уйти без этого.
/// [actionIcon] — значок «уйти из приложения», когда кнопка уводит в Meta AI или в настройки.
struct MetaAiFooter: View {
    let actionText: String
    let action: () -> Void
    let actionIcon: String?
    let dismissText: String
    let onDismiss: () -> Void
    var inverse = false

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            PrimaryButton(
                text: actionText,
                background: inverse ? palette.inverseSurface : nil,
                foreground: inverse ? palette.inverseOnSurface : nil,
                trailingIcon: actionIcon,
                action: action
            )
            Button(action: onDismiss) {
                Text(dismissText).textStyle(Typography.bodyMedium).foregroundStyle(palette.secondary).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm)
    }
}

/// Шаги подключения. [doneHint] — подпись выполненного шага.
enum PairStep: Int, CaseIterable, Comparable {
    case glasses, phone, registration, camera

    var titleKey: String {
        switch self {
        case .glasses: "glasses_pair_step_glasses"
        case .phone: "glasses_onboarding_step_phone"
        case .registration: "glasses_pair_step_registration"
        case .camera: "glasses_pair_step_camera"
        }
    }

    var hintKey: String { titleKey + "_hint" }

    var doneHintKey: String {
        switch self {
        case .registration: "glasses_pair_step_registration_done"
        case .camera: "glasses_pair_step_camera_done"
        default: hintKey
        }
    }

    static func < (lhs: PairStep, rhs: PairStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Первый непройденный шаг, nil — пройдены все. Очки до регистрации SDK не показывает, поэтому этот шаг не проверить.
func currentPairStep(canFindGlasses: Bool, registered: Bool, cameraAllowed: Bool) -> PairStep? {
    if !canFindGlasses { return .phone }
    if !registered { return .registration }
    if !cameraAllowed { return .camera }
    return nil
}

/// Подключение очков по шагам. Разрешения телефона — одним заходом сразу при входе; затем два перехода в Meta AI —
/// подтвердить Qanat и разрешить камеру с микрофоном очков; перед каждым — объяснение и «Продолжить».
struct GlassesPairScreen: View {
    let viewModel: GlassesViewModel
    @State var registration: GlassesRegistrationViewModel
    let controls: MetaGlassesControls
    let onBack: () -> Void
    let onConnected: () -> Void

    @State private var phoneAsked = false
    /// Bluetooth запретили: системное окно больше не появится — ведём в настройки.
    @State private var bluetoothBlocked = CBManager.authorization == .denied || CBManager.authorization == .restricted
    @State private var cameraAllowed = false
    @State private var revealed = 0
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        let step = currentPairStep(canFindGlasses: !bluetoothBlocked && phoneAsked, registered: viewModel.isRegistered, cameraAllowed: cameraAllowed)
        let waitingForMetaAi = step == .registration && registration.attempt.isWaiting
        Group {
            if case .failed = registration.attempt {
                RegistrationHelpScreen(onRetry: registration.retry, onClose: registration.helpClosed)
            } else {
                content(step: step, waiting: waitingForMetaAi)
            }
        }
        .background(palette.background)
        .task { await askPhonePermissions() }
        // Ушли в Meta AI: по возвращении поймём, подтвердил ли он подключение.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { registration.leftApp() }
            if phase == .active {
                registration.returned()
                bluetoothBlocked = CBManager.authorization == .denied || CBManager.authorization == .restricted
            }
        }
        // Пока очки не на связи, SDK и про разрешённую камеру отвечает «нет» — проверяем снова, когда они на связи.
        .task(id: "\(String(describing: step))-\(viewModel.isConnected)-\(scenePhase)") {
            if step == .camera, await controls.missingAudioPermissions().isEmpty { cameraAllowed = true }
        }
        .onChange(of: step) { _, step in if step == nil { onConnected() } }
    }

    private func content(step: PairStep?, waiting: Bool) -> some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("glasses_pair_title"), onBack: onBack)
            ScrollView {
                VStack(spacing: 28) {
                    PairingBadges().padding(.top, 18).padding(.bottom, Spacing.xs)
                    let (title, text) = explanation(step, waiting: waiting)
                    VStack(spacing: Spacing.sm) {
                        Text(L.t(title)).textStyle(BrandText.greeting.size(22, lineHeight: 27.5)).multilineTextAlignment(.center).foregroundStyle(palette.onSurface)
                        Text(L.t(text)).textStyle(Typography.bodyMedium).multilineTextAlignment(.center).foregroundStyle(palette.secondary)
                    }
                    .id(title + text)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeOut(duration: 0.2), value: title + text)
                    SettingsCard {
                        ForEach(PairStep.allCases, id: \.self) { item in
                            if item.rawValue < revealed {
                                if item != .glasses { RowDivider().padding(.leading, 42) }
                                stepRow(item, status(item, current: step)).transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                    }
                    MetaAiFooter(
                        actionText: L.t(step == .phone && bluetoothBlocked ? "glasses_onboarding_open_settings" : (waiting ? "registration_open_again" : "glasses_onboarding_continue")),
                        action: { onContinue(step) },
                        actionIcon: step == .phone && !bluetoothBlocked ? nil : "arrow.up.right.square",
                        dismissText: L.t("common_cancel"),
                        onDismiss: onBack,
                        inverse: true
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
                .readableWidth()
            }
        }
        .task {
            for index in PairStep.allCases.indices {
                withAnimation(.easeOut(duration: 0.2)) { revealed = index + 1 }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Разрешения телефона одним заходом: микрофон — говорить через очки, уведомления — видеть сбои команд с очков.
    private func askPhonePermissions() async {
        guard !phoneAsked else { return }
        _ = await AVAudioApplication.requestRecordPermission()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        phoneAsked = true
    }

    private func onContinue(_ step: PairStep?) {
        switch step {
        case .phone:
            if bluetoothBlocked { openURL(URL(string: UIApplication.openSettingsURLString)!) } else { Task { await askPhonePermissions() } }
        case .registration:
            registration.connect()
        case .camera:
            // Камера и микрофон очков подряд, одним «Продолжить»: голос с очков идёт только через поток камеры.
            Task {
                let missing = await controls.missingAudioPermissions()
                if missing.isEmpty || (await controls.request(missing)) { cameraAllowed = true }
            }
        case .glasses, nil:
            break
        }
    }

    /// Заголовок и объяснение шага: что сейчас произойдёт и что там нажать.
    private func explanation(_ step: PairStep?, waiting: Bool) -> (String, String) {
        switch step {
        case .phone: ("glasses_onboarding_phone_title", bluetoothBlocked ? "glasses_onboarding_phone_blocked_text" : "glasses_onboarding_phone_text")
        case .glasses, .registration: ("glasses_pair_heading", waiting ? "registration_waiting_text" : "glasses_onboarding_registration_text")
        case .camera, nil: ("glasses_onboarding_camera_title", "glasses_onboarding_camera_text")
        }
    }

    private enum StepStatus { case done, active, pending }

    private func status(_ item: PairStep, current: PairStep?) -> StepStatus {
        guard let current else { return .done }
        if item < current { return .done }
        return item == current ? .active : .pending
    }

    private func stepRow(_ item: PairStep, _ status: StepStatus) -> some View {
        HStack(spacing: 14) {
            Group {
                switch status {
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(palette.onPrimary)
                        .frame(width: 28, height: 28).background(palette.tones.connected, in: Circle())
                case .active:
                    ProgressView().tint(palette.primary).frame(width: 28, height: 28)
                case .pending:
                    Circle().stroke(palette.outline, lineWidth: 2).frame(width: 28, height: 28)
                }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t(item.titleKey)).textStyle(Typography.bodyMedium.weight(.medium))
                    .foregroundStyle(status == .pending ? palette.secondary : palette.onSurface)
                Text(L.t(status == .done ? item.doneHintKey : item.hintKey)).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 60)
    }
}

private struct PairingBadges: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Text(brandLetter).textStyle(BrandText.avatarLarge.size(28)).foregroundStyle(palette.onPrimary)
                .frame(width: 72, height: 72)
                .background(palette.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            HStack(spacing: 6) {
                ForEach([1.0, 0.55, 0.25], id: \.self) { alpha in
                    Circle().fill(palette.primary.opacity(alpha)).frame(width: 6, height: 6)
                }
            }
            GlassesBadgeArt().frame(width: 56, height: 22)
                .frame(width: 72, height: 72)
                .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.outline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Подключение не удалось: причины — от самой частой к редкой, затем «Попробовать снова».
struct RegistrationHelpScreen: View {
    let onRetry: () -> Void
    let onClose: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("glasses_pair_title"), onBack: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(L.t("registration_failed_title")).textStyle(BrandText.greeting.size(22, lineHeight: 27.5)).foregroundStyle(palette.onSurface)
                        Text(L.t("registration_failed_text")).textStyle(Typography.bodyMedium).foregroundStyle(palette.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        NumberedStep(number: 1, text: L.t("registration_cause_old_connection"))
                        NumberedStep(number: 2, text: L.t("registration_cause_outdated"))
                    }
                    VStack(spacing: 10) {
                        PrimaryButton(
                            text: L.t("registration_open_meta_ai"),
                            background: palette.secondaryContainer,
                            foreground: palette.onSecondaryContainer,
                            trailingIcon: "arrow.up.right.square"
                        ) { openMetaAi(openURL) }
                        PrimaryButton(text: L.t("registration_retry"), action: onRetry)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
                .readableWidth()
            }
        }
        .background(palette.background)
    }
}

/// Открывает Meta AI, а если его нет — его страницу в App Store.
func openMetaAi(_ openURL: OpenURLAction) {
    if let app = URL(string: "fb-viewapp://"), UIApplication.shared.canOpenURL(app) {
        openURL(app)
    } else {
        openURL(metaAiStoreURL)
    }
}
