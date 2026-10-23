import Combine
import Foundation

/// Корень композиции: создаёт и связывает зависимости приложения (на Android — модули Hilt). Синглтоны живут, пока
/// живёт процесс; ViewModel экранов — пока пользователь не вышел ([SignedInModels]).
@MainActor
final class AppContainer {
    let tokenStorage: TokenStorage
    let preferencesStorage: PreferencesStorage
    let api: ApiClient
    let deviceInfo: DeviceInfoProvider
    let chatPushEvents = ChatPushEvents()

    let glasses = MetaGlassesControls()
    let bluetooth = PhoneBluetooth()
    let tones = TonePlayer()
    let audioPermissionPrompt = GlassesAudioPermissionPrompt()

    let authRepository: AuthRepository
    let settingsRepository: SettingsRepository
    let profileRepository: ProfileRepositoryImpl
    let chatRepository: ChatRepository
    let documents: DocumentRepository
    let photos: PhotoRepository
    let videos: VideoRepository
    let media: GlassesMediaRepository
    let signals: GlassesSignals
    let voiceRepository: VoiceRepository
    let voice: HandsFreeVoice

    init() {
        // Связка ключей переживает удаление приложения: после переустановки начинаем без старой сессии.
        let tokenStorage = KeychainTokenStorage()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.launchedKey) {
            tokenStorage.clear()
            defaults.set(true, forKey: Self.launchedKey)
        }
        self.tokenStorage = tokenStorage
        preferencesStorage = UserDefaultsPreferencesStorage()
        let authenticator = TokenAuthenticator(tokenStorage: tokenStorage, baseURL: AppConfig.baseURL)
        api = ApiClient(baseURL: AppConfig.baseURL, tokenStorage: tokenStorage, authenticator: authenticator)
        ImageLoader.shared = ImageLoader(api: api)
        deviceInfo = FirebaseDeviceInfoProvider()

        authRepository = AuthRepositoryImpl(api: api, tokenStorage: tokenStorage, preferencesStorage: preferencesStorage, deviceInfo: deviceInfo)
        settingsRepository = SettingsRepositoryImpl(api: api, deviceInfo: deviceInfo, preferencesStorage: preferencesStorage)
        profileRepository = ProfileRepositoryImpl(api: api)
        chatRepository = ChatRepositoryImpl(api: api, answers: AgentAnswerStream(api: api))
        documents = DocumentRepositoryImpl(api: api, deviceInfo: deviceInfo)
        photos = PhotoRepositoryImpl(api: api)
        videos = VideoRepositoryImpl(api: api)
        media = GlassesMediaRepositoryImpl(preferencesStorage: preferencesStorage)
        signals = GlassesSignalPlayer(tones: tones)
        voiceRepository = VoiceRepositoryImpl(
            recorder: PcmRecorder(),
            player: PcmPlayer(),
            noteRecorder: NoteRecorder(),
            datNotes: DatNoteRecorder(capture: glasses, camera: glasses, tones: tones),
            glassesMicrophone: GlassesConversationMicrophone(capture: glasses),
            audioPermissionPrompt: audioPermissionPrompt,
            signals: SignalPlayer(tones: tones, preferencesStorage: preferencesStorage),
            tones: tones,
            speech: SpeechPlayer(),
            socket: VoiceSocket(tokenStorage: tokenStorage, authenticator: authenticator),
            glasses: glasses,
            look: GlassesLook(preferencesStorage: preferencesStorage, glasses: glasses, camera: glasses, photos: photos, media: media),
            chats: chatRepository,
            preferencesStorage: preferencesStorage
        )
        voice = HandsFreeVoice(repository: voiceRepository, glasses: glasses, chat: HandsFreeChat(repository: voiceRepository))
    }

    private static let launchedKey = "launched_before"

    /// Чаты, в которые голосовой разговор только что записал вопрос или ответ, — для открытого экрана чата.
    func voiceChatChanges() -> AsyncStream<String> {
        let changes = voice.chatChanges
        return AsyncStream { continuation in
            let subscription = changes.sink { continuation.yield($0) }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}

/// ViewModel экранов вошедшего пользователя. Как hiltViewModel() в одной Activity на Android, каждый живёт с первого
/// показа экрана и до выхода из аккаунта: вернувшись на экран, пользователь видит его прежним.
@MainActor
final class SignedInModels {
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    lazy var chat = ChatViewModel(
        repository: container.chatRepository,
        voiceRecorder: AVVoiceNoteRecorder(),
        voicePlayer: AVVoicePlayer(chats: container.chatRepository),
        profileRepository: container.profileRepository,
        glassesControls: container.glasses,
        photos: container.photos,
        preferencesStorage: container.preferencesStorage,
        documents: container.documents,
        pushEvents: container.chatPushEvents
    )
    lazy var documents = DocumentsViewModel(documents: container.documents)
    lazy var templates = LetterTemplatesViewModel(documents: container.documents)
    lazy var settings = SettingsViewModel(repository: container.settingsRepository, preferencesStorage: container.preferencesStorage, glasses: container.glasses)
    lazy var profile = ProfileViewModel(repository: container.profileRepository, avatarRepository: container.profileRepository, authRepository: container.authRepository)
    lazy var glasses = GlassesViewModel(glasses: container.glasses, repository: container.media, preferencesStorage: container.preferencesStorage)
    lazy var registration = GlassesRegistrationViewModel(controls: container.glasses)
    lazy var gallery = GalleryViewModel(repository: container.media, photos: container.photos, videos: container.videos)
    lazy var check = GlassesCheckViewModel(
        glasses: container.glasses,
        link: container.glasses,
        bluetooth: container.bluetooth,
        permissions: container.glasses,
        audio: container.glasses,
        camera: container.glasses,
        signals: container.signals,
        voice: container.voice
    )
    lazy var micProbe = GlassesMicProbeViewModel(audio: container.glasses)

    /// Экран документа — свой ViewModel на каждый открытый документ.
    func document(_ id: String) -> DocumentViewModel {
        if let cached = documentModel, cached.id == id { return cached.model }
        let model = DocumentViewModel(documents: container.documents, documentId: id)
        documentModel = (id, model)
        return model
    }

    private var documentModel: (id: String, model: DocumentViewModel)?
}
