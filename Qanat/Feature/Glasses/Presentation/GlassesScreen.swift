import AVFoundation
import Combine
import SwiftUI

/// Экран «Смарт-очки» только показывает очки и снимки: съёмку кнопкой ведёт [GlassesCapture].
@MainActor
@Observable
final class GlassesViewModel {
    /// Qanat подключён к очкам через Meta AI.
    private(set) var isRegistered = false
    private(set) var deviceInfo: GlassesDeviceInfo?
    private(set) var media: [CapturedMedia] = []
    private(set) var preferences = AppPreferences()

    private let preferencesStorage: PreferencesStorage
    private var subscriptions = Set<AnyCancellable>()

    init(glasses: GlassesControls, repository: GlassesMediaRepository, preferencesStorage: PreferencesStorage) {
        self.preferencesStorage = preferencesStorage
        glasses.isRegistered.receive(on: DispatchQueue.main).sink { [weak self] in self?.isRegistered = $0 }.store(in: &subscriptions)
        glasses.deviceInfo.receive(on: DispatchQueue.main).sink { [weak self] in self?.deviceInfo = $0 }.store(in: &subscriptions)
        repository.media.receive(on: DispatchQueue.main).sink { [weak self] in self?.media = $0 }.store(in: &subscriptions)
        preferencesStorage.preferences.receive(on: DispatchQueue.main).sink { [weak self] in self?.preferences = $0 }.store(in: &subscriptions)
    }

    /// Очки на связи прямо сейчас: нужны и регистрация, и живое подключение.
    var isConnected: Bool { isRegistered && deviceInfo?.isConnected == true }
    /// Имя очков — только пока Qanat к ним подключён.
    var deviceName: String? { isRegistered ? deviceInfo?.name : nil }
    /// Заряд — только пока очки на связи: после отключения SDK больше не обновляет его.
    var batteryLevel: Int? { isConnected ? deviceInfo?.batteryLevel : nil }
    var isCharging: Bool { isConnected && deviceInfo?.isCharging == true }
    /// Надеты ли очки — тоже только пока на связи; nil — неизвестно.
    var isWorn: Bool? { isConnected ? deviceInfo?.isWorn : nil }
    var status: GlassesStatus { glassesStatus(registered: isRegistered, info: deviceInfo) }

    func setVoiceReplies(_ enabled: Bool) { preferencesStorage.update { $0.glassesVoiceReplies = enabled } }
    func setVision(_ enabled: Bool) { preferencesStorage.update { $0.glassesVision = enabled } }
    func setSaveToGallery(_ enabled: Bool) { preferencesStorage.update { $0.glassesSaveToGallery = enabled } }
}

struct GlassesScreen: View {
    @State var viewModel: GlassesViewModel
    let controls: MetaGlassesControls
    let onClose: () -> Void
    let onOpenGuide: () -> Void
    let onOpenGallery: () -> Void
    let onOpenCheck: () -> Void
    let onConnect: () -> Void

    @State private var confirmUnbind = false
    @State private var cameraAllowed: Bool?
    @State private var micAllowed: Bool?
    /// Звук очков идёт через поток их камеры: нужны и микрофон, и камера в Meta AI. nil — не знаем.
    @State private var glassesMicAllowed: Bool?
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let glassesOnLink = viewModel.status != .notConnected && viewModel.status != .offline
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("glasses_title"), onBack: onClose)
            ScrollView {
                VStack(spacing: 14) {
                    deviceCard
                    if viewModel.isRegistered {
                        permissionCards
                        if let allowed = glassesMicAllowed { glassesMicRow(allowed) }
                    }
                    GalleryPreviewCard(media: viewModel.media, action: onOpenGallery)
                    SettingsCard {
                        if viewModel.isRegistered {
                            // Инструкция — спокойной строкой в списке: её открывают, когда нужно.
                            LinkRow(title: L.t("glasses_guide_button"), action: onOpenGuide)
                            RowDivider()
                            // Пройти проверку снова — когда что-то из очков перестало работать.
                            LinkRow(title: L.t("glasses_check_title"), subtitle: L.t("glasses_check_row_hint"), action: onOpenCheck)
                            RowDivider()
                            ToggleRow(title: L.t("glasses_voice_replies"), isOn: viewModel.preferences.glassesVoiceReplies, onChange: viewModel.setVoiceReplies)
                            RowDivider()
                            ToggleRow(title: L.t("glasses_vision"), subtitle: L.t("glasses_vision_hint"), isOn: viewModel.preferences.glassesVision, onChange: viewModel.setVision)
                            RowDivider()
                            ToggleRow(title: L.t("gallery_save_to_phone"), subtitle: L.t("gallery_save_to_phone_hint"), isOn: viewModel.preferences.glassesSaveToGallery, onChange: viewModel.setSaveToGallery)
                            RowDivider()
                            // Отвязка — до удаления Qanat: иначе Meta AI запомнит старое подключение и новое не пройдёт.
                            LinkRow(title: L.t("registration_unbind"), subtitle: L.t("registration_unbind_hint"), titleColor: palette.error) { confirmUnbind = true }
                        } else {
                            LinkRow(title: L.t("glasses_connect_via_meta"), trailingIcon: "arrow.up.right.square", action: onConnect)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .readableWidth()
            }
        }
        .background(palette.background)
        // Камеру разрешают в Meta AI, микрофон — в настройках системы: оба могли поменять, пока экран был свёрнут.
        .task(id: "\(scenePhase)-\(glassesOnLink)") {
            micAllowed = AVAudioApplication.shared.recordPermission == .granted
            cameraAllowed = await controls.isGranted(.camera)
            glassesMicAllowed = glassesOnLink ? await controls.missingAudioPermissions().isEmpty : nil
        }
        .alert(L.t("glasses_unbind_confirm_title"), isPresented: $confirmUnbind) {
            Button(L.t("common_cancel"), role: .cancel) {}
            Button(L.t("glasses_unbind_confirm"), role: .destructive) { Task { await controls.startUnregistration() } }
        } message: {
            Text(L.t("glasses_unbind_confirm_text"))
        }
    }

    private var deviceCard: some View {
        VStack(spacing: 16) {
            GlassesFrontArt().frame(maxWidth: 290).aspectRatio(290 / 106, contentMode: .fit)
            VStack(spacing: 4) {
                Text(viewModel.deviceName ?? L.t("glasses_not_connected")).textStyle(Typography.titleLarge).foregroundStyle(palette.onSurface)
                // Бирюзовый — только когда очки на связи и надеты.
                if let (dot, text) = statusLine {
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(text).textStyle(Typography.bodySmall)
                            .foregroundStyle(viewModel.status == .ready ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                    }
                }
                if viewModel.batteryLevel != nil || viewModel.isWorn != nil {
                    FlowLayout(horizontalSpacing: 14, verticalSpacing: 4) {
                        if let battery = viewModel.batteryLevel {
                            deviceStatus(
                                viewModel.isCharging ? "battery.100.bolt" : "battery.75",
                                L.t(viewModel.isCharging ? "glasses_battery_charging" : "glasses_battery", battery)
                            )
                        }
                        if let worn = viewModel.isWorn {
                            deviceStatus(worn ? "face.smiling" : "eyeglasses", L.t(worn ? "glasses_worn" : "glasses_not_worn"))
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 18)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var statusLine: (Color, String)? {
        switch viewModel.status {
        case .notConnected: nil
        case .offline: (palette.outline, L.t("glasses_status_offline"))
        case .takenOff: (palette.tones.warning, L.t("glasses_status_taken_off"))
        case .connected: (palette.outline, L.t("glasses_connected_via_meta"))
        case .ready: (palette.tones.connected, L.t("glasses_connected_via_meta"))
        }
    }

    private func deviceStatus(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13))
            Text(text).textStyle(Typography.bodySmall)
        }
        .foregroundStyle(palette.onSurfaceVariant)
    }

    /// Камера и микрофон — рядом, пока в каждой карточке тексту остаётся место; иначе одна под другой.
    private var permissionCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                cameraCard.frame(minWidth: 138)
                micCard.frame(minWidth: 138)
            }
            VStack(spacing: 10) {
                cameraCard
                micCard
            }
        }
    }

    private var cameraCard: some View {
        statusCard("camera", L.t("glasses_camera_section"), cameraAllowed, L.t("glasses_permission_camera_granted"), L.t("glasses_permission_camera_denied"))
    }

    private var micCard: some View {
        statusCard("mic", L.t("glasses_mic_section"), micAllowed, L.t("glasses_permission_mic_granted"), L.t("glasses_permission_mic_denied"))
    }

    /// [allowed] nil — разрешение ещё проверяем: строка статуса пустая, чтобы карточка не прыгала по высоте.
    private func statusCard(_ icon: String, _ title: String, _ allowed: Bool?, _ allowedText: String, _ deniedText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(palette.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(Typography.bodyMedium.weight(.semibold)).foregroundStyle(palette.onSurface)
                Text(allowed == true ? allowedText : (allowed == false ? deniedText : " "))
                    .textStyle(Typography.bodySmall)
                    .foregroundStyle(allowed == false ? palette.error : palette.onPrimaryContainer)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    /// Микрофон очков в Meta AI: есть ли доступ, а если нет — разрешить (вместе с камерой, если и её нет).
    private func glassesMicRow(_ allowed: Bool) -> some View {
        SettingsCard {
            if allowed {
                HStack(spacing: 12) {
                    Image(systemName: "mic").foregroundStyle(palette.primary)
                    Text(L.t("glasses_mic_access_granted")).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurface)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            } else {
                LinkRow(title: L.t("glasses_mic_access_denied"), titleColor: palette.error) {
                    Task {
                        _ = await controls.request(await controls.missingAudioPermissions())
                        glassesMicAllowed = await controls.missingAudioPermissions().isEmpty
                    }
                }
            }
        }
    }
}

/// Превью галереи: всегда четыре ячейки — при 1–3 снимках они не растягиваются на всю ширину.
struct GalleryPreviewCard: View {
    let media: [CapturedMedia]
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("gallery_title")).textStyle(Typography.titleSmall).foregroundStyle(palette.onSurface)
                        Text(L.t("glasses_gallery_subtitle")).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(palette.onSurfaceVariant)
                }
                if !media.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { index in
                            if index < media.count {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(MediaThumbnail(item: media[index]))
                                    .background(palette.surfaceContainerHigh)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
