import SwiftUI

struct SettingsScreen: View {
    @State var viewModel: SettingsViewModel
    let onLogout: () -> Void
    let onClose: () -> Void
    let onOpenGlasses: () -> Void
    let onConnectGlasses: () -> Void
    let onOpenProfile: (_ email: String) -> Void
    /// Проба микрофона очков — инструмент разработчика: в release её нет.
    var micProbe: ((_ connected: Bool) -> GlassesMicProbeRow)?

    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var theme = ThemeSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("settings_title"), onBack: onClose)
            ScrollView {
                VStack(spacing: 14) {
                    SettingsCard { profileCard }

                    section(L.t("settings_devices_section")) {
                        SettingsCard {
                            GlassesRow(
                                status: viewModel.glassesStatus,
                                deviceName: viewModel.glassesInfo?.name,
                                action: viewModel.isGlassesRegistered ? onOpenGlasses : onConnectGlasses
                            )
                            if AppConfig.isDebug, viewModel.isGlassesRegistered, let micProbe {
                                RowDivider()
                                micProbe(viewModel.glassesInfo?.isConnected == true)
                            }
                        }
                    }

                    section(L.t("settings_voice_section")) {
                        SettingsCard {
                            ToggleRow(
                                title: L.t("settings_voice_reply"),
                                subtitle: L.t("settings_voice_reply_hint"),
                                isOn: viewModel.preferences.voiceReplyToNotes,
                                onChange: viewModel.setVoiceReply
                            )
                            RowDivider()
                            ToggleRow(
                                title: L.t("settings_speak_answers"),
                                subtitle: L.t("settings_speak_answers_hint"),
                                isOn: viewModel.preferences.speakAnswers,
                                onChange: viewModel.setSpeakAnswers
                            )
                            RowDivider()
                            ToggleRow(
                                title: L.t("settings_start_end_sounds"),
                                subtitle: L.t("settings_start_end_sounds_hint"),
                                isOn: viewModel.preferences.startEndSounds,
                                onChange: viewModel.setStartEndSounds
                            )
                            // Только для голосовых с очков: без очков переключатель не нужен, а его значение сохраняется.
                            if viewModel.isGlassesRegistered {
                                RowDivider()
                                ToggleRow(
                                    title: L.t("glasses_voice_replies"),
                                    subtitle: L.t("glasses_voice_replies_hint"),
                                    isOn: viewModel.preferences.glassesVoiceReplies,
                                    onChange: viewModel.setGlassesVoiceReplies
                                )
                                RowDivider()
                                ToggleRow(
                                    title: L.t("gallery_save_to_phone"),
                                    subtitle: L.t("gallery_save_to_phone_hint"),
                                    isOn: viewModel.preferences.glassesSaveToGallery,
                                    onChange: viewModel.setGlassesSaveToGallery
                                )
                            }
                        }
                    }

                    section(L.t("settings_theme_section")) {
                        let options: [(AppTheme, String)] = [
                            (.system, L.t("settings_theme_system")),
                            (.light, L.t("settings_theme_light")),
                            (.dark, L.t("settings_theme_dark")),
                        ]
                        ChoiceList(
                            options: options.map(\.1),
                            selectedIndex: options.firstIndex { $0.0 == theme.theme } ?? 0,
                            onSelect: { theme.theme = options[$0].0 }
                        )
                    }

                    section(L.t("settings_language_section")) {
                        let languages = AppLanguage.allCases
                        ChoiceList(
                            options: languages.map { L.t("settings_language_\($0.tag)") },
                            selectedIndex: languages.firstIndex(of: viewModel.language) ?? 0,
                            onSelect: { viewModel.selectLanguage(languages[$0]) }
                        )
                    }

                    section(L.t("settings_about_section")) {
                        SettingsCard {
                            LinkRow(title: L.t("settings_privacy_policy"), trailingIcon: "arrow.up.right.square") {
                                openURL(sitePageURL(.privacy))
                            }
                            RowDivider()
                            LinkRow(title: L.t("settings_data_deletion"), trailingIcon: "arrow.up.right.square") {
                                openURL(sitePageURL(.dataDeletion))
                            }
                            RowDivider()
                            Text(L.t("settings_build_beta", AppConfig.appVersion))
                                .textStyle(Typography.bodyMedium)
                                .foregroundStyle(palette.onSurfaceVariant)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .padding(.horizontal, 16)
                        }
                    }

                    SettingsCard {
                        ToggleRow(
                            title: L.t("settings_push"),
                            isOn: viewModel.pendingPush ?? (viewModel.preferences.pushEnabled && viewModel.notificationsAllowed),
                            onChange: { enabled in
                                viewModel.togglePush(enabled)
                                // Системный запрет приложение снять не может — открываем настройки, где его снимают.
                                if enabled && !viewModel.notificationsAllowed {
                                    openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                                }
                            }
                        )
                        RowDivider()
                        LinkRow(title: L.t("settings_logout"), titleColor: palette.error, minHeight: 56, action: onLogout)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.lg)
                .readableWidth()
            }
        }
        .background(palette.background)
        .snackbar(message: viewModel.pushErrorKey.map { L.t($0) }) { viewModel.pushErrorKey = nil }
        .task { await viewModel.load() }
        .task(id: scenePhase) { await viewModel.refreshNotificationsAllowed() }
    }

    @ViewBuilder
    private var profileCard: some View {
        if viewModel.isLoading {
            ProgressView().padding(Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        } else if let key = viewModel.errorKey {
            Text(L.t(key)).foregroundStyle(palette.error).padding(Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        } else if let profile = viewModel.profile {
            Button { onOpenProfile(profile.email) } label: {
                HStack(spacing: 12) {
                    Avatar(
                        initials: initials(of: profile.displayName),
                        imageURL: profile.avatarURL,
                        size: 44,
                        textStyle: Typography.titleMedium.size(16)
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName).textStyle(Typography.titleMedium).foregroundStyle(palette.onSurface)
                        Text(L.t("settings_profile_subtitle")).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressHighlightStyle())
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: Spacing.sm) {
            SectionHeader(text: title)
            content()
        }
    }
}

/// Выбор одного из вариантов строками с галочкой, как в системных настройках: влезает при любом размере шрифта.
private struct ChoiceList: View {
    let options: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        SettingsCard {
            ForEach(options.indices, id: \.self) { index in
                if index > 0 { RowDivider() }
                Button { onSelect(index) } label: {
                    HStack(spacing: 12) {
                        Text(options[index]).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index == selectedIndex {
                            Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressHighlightStyle())
                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
            }
        }
    }
}

private struct GlassesRow: View {
    let status: GlassesStatus
    let deviceName: String?
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        // Очки не добавлены — одна нейтральная строка «Подключить очки», без статуса и цвета.
        let registered = status != .notConnected
        Button(action: action) {
            HStack(spacing: 12) {
                GlassesIcon(tint: registered ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 40)
                    .background(registered ? palette.primaryContainer : palette.surfaceVariant, in: RoundedRectangle(cornerRadius: Radius.small))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(registered ? "glasses_title" : "voice_glasses_connect"))
                        .textStyle(Typography.bodyLarge.weight(.medium))
                        .foregroundStyle(palette.onSurface)
                    if registered {
                        GlassesStatusLine(status: status, deviceName: deviceName)
                    } else {
                        Text(L.t("settings_glasses_connect_hint")).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressHighlightStyle())
    }
}
