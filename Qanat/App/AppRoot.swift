import Combine
import SwiftUI

enum SignedInScreen {
    case chat, voice, settings, glassesEmpty, glassesPair, glassesCheck, glasses, glassesGuide, gallery, profile, document
}

/// Какой экран показать. Идущий разговор (даже начатый с очков) показывает голосовой экран, пока пользователь сам
/// не ушёл с него в этом разговоре ([leftVoice]): тогда разговор идёт дальше, а виден выбранный экран [chosen].
/// Без разговора — всегда [chosen], по умолчанию чат.
func signedInScreen(chosen: SignedInScreen?, conversation: Bool, leftVoice: Bool) -> SignedInScreen {
    conversation && !leftVoice ? .voice : chosen ?? .chat
}

/// uid/token из ссылки письма: `https://qm.e-vko.kz/auth/reset?uid=&token=`. nil — ссылка не про сброс пароля.
struct ResetLink: Equatable {
    let uid: String
    let token: String

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "qm.e-vko.kz", components.path.hasPrefix("/auth/reset"),
              let uid = components.queryItems?.first(where: { $0.name == "uid" })?.value,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return nil }
        self.uid = uid
        self.token = token
    }
}

private enum AuthScreen: Equatable {
    case login, forgot
    case reset(ResetLink)
}

/// Экран определяется только состоянием сессии: вход сохраняет токены — показываем основной экран,
/// выход или отказ сервера в refresh очищают их — возвращаемся на логин.
struct AppRoot: View {
    let container: AppContainer

    @State private var signedIn: Bool?
    @State private var authScreen: AuthScreen = .login
    @State private var models: SignedInModels?
    @State private var session: SignedInSession?
    @State private var theme = ThemeSettings.shared
    @State private var language = LanguageSettings.shared

    var body: some View {
        content
            .measuresWindowLayout()
            .qanatTheme()
            .preferredColorScheme(theme.theme.colorScheme)
            // Смена языка в настройках перерисовывает всё приложение с новыми строками.
            .id(language.language)
            .onReceive(container.tokenStorage.tokens.receive(on: DispatchQueue.main)) { tokens in
                updateSession(signedIn: tokens != nil)
            }
            .onOpenURL { url in
                // Ссылку из письма можно открыть и при активной сессии — сбрасываем пароль, не трогая её.
                if let link = ResetLink(url) { authScreen = .reset(link) } else { GlassesSdk.handle(url) }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let link = ResetLink(url) { authScreen = .reset(link) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if case .reset(let link) = authScreen {
            ResetPasswordScreen(
                viewModel: ResetPasswordViewModel(repository: container.authRepository, uid: link.uid, token: link.token),
                onDone: { authScreen = .login }
            )
            .id(link.token)
        } else if signedIn == false {
            if authScreen == .forgot {
                ForgotPasswordScreen(viewModel: ForgotPasswordViewModel(repository: container.authRepository), onBack: { authScreen = .login })
            } else {
                LoginScreen(viewModel: LoginViewModel(login: LoginUseCase(repository: container.authRepository)), onForgotPassword: { authScreen = .forgot })
            }
        } else if signedIn == true, let models {
            SignedInContent(container: container, models: models, onLogout: logout)
        } else {
            Color.clear
        }
    }

    private func updateSession(signedIn: Bool) {
        guard self.signedIn != signedIn else { return }
        self.signedIn = signedIn
        if signedIn {
            models = SignedInModels(container: container)
            let session = SignedInSession(container: container)
            session.start()
            self.session = session
        } else {
            session?.stop()
            session = nil
            models = nil
        }
    }

    private func logout() {
        Task { await container.authRepository.logout() }
    }
}

/// Главный экран — чаты с агентом; голосовой режим и настройки открываются поверх и закрываются «назад».
private struct SignedInContent: View {
    let container: AppContainer
    let models: SignedInModels
    let onLogout: () -> Void

    @State private var manualScreen: SignedInScreen?
    @State private var profileEmail = ""
    // Очки, галерея и инструкция открываются из нескольких мест — «назад» должен вернуть туда, откуда пришли.
    @State private var glassesBackTarget: SignedInScreen = .chat
    @State private var galleryBackTarget: SignedInScreen = .glasses
    @State private var guideBackTarget: SignedInScreen = .glasses
    @State private var checkBackTarget: SignedInScreen = .glasses
    @State private var emptyBackTarget: SignedInScreen = .settings
    // Документ открывают из меню чатов: «назад» возвращает в меню на «Документы», а «Из чата» — в сам чат.
    @State private var openedDocumentId: String?
    @State private var reopenDocuments = false
    /// Чат, который откроет экран чата: из push, из документа или чат разговора, с экрана которого ушли.
    @State private var chatToOpen: String?
    /// Разговор, с экрана которого пользователь ушёл, — его экран голоса больше не навязывает. Привязан к номеру
    /// разговора: следующий разговор (хоть и начатый в фоне) снова откроет экран.
    @State private var leftVoiceConversation: Int?
    /// Разговор, начатый на этом заходе на экран голоса, — его чат и откроет «Чат», даже когда разговор уже кончился.
    @State private var conversationAtVoiceEntry = 0
    @State private var voiceNoticeAction: VoiceNoticeAction?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.windowLayout) private var layout

    private var voice: HandsFreeVoice { container.voice }

    var body: some View {
        let conversation = voice.state.isConversation
        let current = signedInScreen(chosen: manualScreen, conversation: conversation, leftVoice: leftVoiceConversation == voice.conversation)
        screen(current, conversation: conversation)
            .onChange(of: current) { old, new in
                if new == .voice, old != .voice { conversationAtVoiceEntry = voice.conversation }
            }
            // Тап по push мог застать пользователя на любом экране — сначала выходим на чат, чтобы было куда открыть.
            .onReceive(PushSetup.shared.openedChatId.compactMap { $0 }) { chatId in
                PushSetup.shared.openedChatId.send(nil)
                chatToOpen = chatId
                manualScreen = .chat
            }
            // Уведомление о сбое команды с очков открывает экран голоса: там ошибка и то, что выбрали в уведомлении.
            .onReceive(PushSetup.shared.voiceNoticeAction.compactMap { $0 }) { action in
                PushSetup.shared.voiceNoticeAction.send(nil)
                voiceNoticeAction = action
                openVoice()
            }
            .task(id: scenePhase) { await askCameraPermission() }
            .onChange(of: container.audioPermissionPrompt.pending, initial: true) { askAudioPermissions() }
    }

    @ViewBuilder
    private func screen(_ current: SignedInScreen, conversation: Bool) -> some View {
        switch current {
        case .voice:
            VoiceScreen(
                voice: voice,
                glasses: container.glasses,
                glassesPermissions: container.glasses,
                permissionRequester: container.glasses,
                // «Назад» во время разговора — тоже в его чат: иначе панель была бы над лентой, куда он не пишет.
                onClose: { leaveVoice(conversationChat: conversation || voice.conversation != conversationAtVoiceEntry) },
                // Подключение — тем же экраном, что из настроек.
                onConnectGlasses: {
                    emptyBackTarget = .voice
                    manualScreen = .glassesEmpty
                },
                noticeAction: $voiceNoticeAction
            )
        case .settings:
            SettingsScreen(
                viewModel: models.settings,
                onLogout: onLogout,
                onClose: { manualScreen = .chat },
                onOpenGlasses: {
                    glassesBackTarget = .settings
                    manualScreen = .glasses
                },
                onConnectGlasses: {
                    emptyBackTarget = .settings
                    manualScreen = .glassesEmpty
                },
                onOpenProfile: { email in
                    profileEmail = email
                    manualScreen = .profile
                },
                micProbe: { connected in
                    GlassesMicProbeRow(viewModel: models.micProbe, connected: connected, permissions: container.glasses, permissionRequester: container.glasses)
                }
            )
        case .glassesEmpty:
            GlassesEmptyScreen(onClose: { manualScreen = emptyBackTarget }, onRegistrationStarted: { manualScreen = .glassesPair })
        case .glassesPair:
            GlassesPairScreen(
                viewModel: models.glasses,
                registration: models.registration,
                controls: container.glasses,
                onBack: { manualScreen = .glassesEmpty },
                // Очки подключены — сразу проверка. С неё — на экран очков, а «назад» с него ведёт туда, откуда
                // начали подключение (настройки или голосовой режим).
                onConnected: {
                    if emptyBackTarget != .glasses { glassesBackTarget = emptyBackTarget }
                    checkBackTarget = .glasses
                    manualScreen = .glassesCheck
                }
            )
        case .glassesCheck:
            GlassesCheckScreen(
                viewModel: models.check,
                permissions: container.glasses,
                permissionRequester: container.glasses,
                onBack: { manualScreen = checkBackTarget },
                onDone: { manualScreen = checkBackTarget },
                // Qanat не подключён к очкам — тем же подключением, что с экрана очков; после него проверка откроется снова.
                onConnect: {
                    emptyBackTarget = .glasses
                    manualScreen = .glassesEmpty
                }
            )
        case .profile:
            ProfileScreen(viewModel: models.profile, email: profileEmail, onDone: { manualScreen = .settings })
        case .glasses:
            GlassesScreen(
                viewModel: models.glasses,
                controls: container.glasses,
                onClose: { manualScreen = glassesBackTarget },
                onOpenGuide: {
                    guideBackTarget = .glasses
                    manualScreen = .glassesGuide
                },
                onOpenGallery: {
                    galleryBackTarget = .glasses
                    manualScreen = .gallery
                },
                onOpenCheck: {
                    checkBackTarget = .glasses
                    manualScreen = .glassesCheck
                },
                onConnect: {
                    emptyBackTarget = .glasses
                    manualScreen = .glassesEmpty
                }
            )
        case .glassesGuide:
            GlassesGuideScreen(
                onClose: { manualScreen = guideBackTarget },
                onOpenCheck: {
                    checkBackTarget = .glassesGuide
                    manualScreen = .glassesCheck
                }
            )
        case .gallery:
            GalleryScreen(
                viewModel: models.gallery,
                onClose: { manualScreen = galleryBackTarget },
                onOpenGuide: {
                    guideBackTarget = .gallery
                    manualScreen = .glassesGuide
                }
            )
        case .document:
            if let id = openedDocumentId {
                DocumentScreen(
                    viewModel: models.document(id),
                    onBack: {
                        reopenDocuments = true
                        manualScreen = .chat
                    },
                    onOpenChat: { chatId in
                        chatToOpen = chatId
                        manualScreen = .chat
                    }
                )
                .id(id)
            }
        case .chat:
            ChatScreen(
                viewModel: models.chat,
                documentsViewModel: models.documents,
                templatesViewModel: models.templates,
                onOpenVoice: { chatId in
                    voice.useChatOnScreen(chatId)
                    openVoice()
                },
                onOpenSettings: { manualScreen = .settings },
                onOpenGlasses: {
                    glassesBackTarget = .chat
                    manualScreen = .glasses
                },
                onOpenGallery: {
                    galleryBackTarget = .chat
                    manualScreen = .gallery
                },
                onOpenGlassesGuide: {
                    guideBackTarget = .chat
                    manualScreen = .glassesGuide
                },
                onOpenDocument: { id in
                    openedDocumentId = id
                    manualScreen = .document
                },
                initialChatId: $chatToOpen,
                showDocuments: $reopenDocuments,
                chatChanges: container.voiceChatChanges,
                voiceTrace: voice.liveTrace,
                voicePanel: voicePanel
            )
        }
    }

    private var voicePanel: AnyView? {
        guard let status = voicePanelStatus(voice.state, muted: voice.muted) else { return nil }
        let failed = if case .failed = status { true } else { false }
        return AnyView(VoiceChatPanel(
            status: status,
            compact: layout.compactHeight,
            onOpenVoice: openVoice,
            onEnd: failed ? voice.dismissError : voice.endConversation
        ))
    }

    private func openVoice() {
        leftVoiceConversation = nil
        manualScreen = .voice
    }

    /// В чат — не прерывая разговор: он идёт в фоне, а в чате видна его панель. [conversationChat] — открыть чат,
    /// в который пишет разговор (его ещё нет — остаётся прежний).
    private func leaveVoice(conversationChat: Bool) {
        if conversationChat, let chatId = voice.conversationChatId() { chatToOpen = chatId }
        // Ошибку на экране голоса пользователь уже видел — в чате её панель не нужна.
        leftVoiceConversation = voice.conversation
        voice.dismissError()
        manualScreen = .chat
    }

    /// Камеру очков просим, как только очки на связи (кроме экрана подключения: там её просит свой шаг), и только
    /// пока приложение на экране: Meta AI открывается поверх него.
    private func askCameraPermission() async {
        container.audioPermissionPrompt.screenVisible = scenePhase == .active
        guard scenePhase == .active else { return }
        let glasses = container.glasses
        for await connected in glasses.deviceInfo.map({ $0?.isConnected == true }).removeDuplicates().values where connected {
            if manualScreen != .glassesPair, !(await glasses.isGranted(.camera)) {
                _ = await glasses.request([.camera])
            }
        }
    }

    /// Голосовое или разговор с очков не начались без камеры и микрофона очков — просим их в Meta AI.
    private func askAudioPermissions() {
        let prompt = container.audioPermissionPrompt
        guard prompt.pending else { return }
        prompt.pending = false
        let glasses = container.glasses
        Task { _ = await glasses.request(await glasses.missingAudioPermissions()) }
    }
}
