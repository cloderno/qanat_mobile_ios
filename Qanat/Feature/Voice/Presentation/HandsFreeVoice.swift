import Combine
import Foundation

enum VoiceUiState: Equatable {
    case idle
    case connecting
    /// Разговор идёт: микрофон открыт, ответы Каната звучат по мере прихода. [kanat] — что он сейчас делает.
    case talking(subtitle: String?, heard: HeardText?, kanat: KanatActivity)
    /// Пишется голосовое сообщение с очков.
    case recordingNote
    /// Голосовое записано и уходит в чат — сервер ещё не подтвердил, что сохранил его.
    case sendingNote
    /// Голосовое сохранено, ответ Каната звучит в очках; его можно остановить, не дослушивая.
    case answeringNote
    /// [glassesMicrophone] — не пошёл микрофон очков: чем тут можно помочь; nil — ошибка не про него.
    case error(messageKey: String, glassesMicrophone: GlassesMicrophoneHelp?)

    /// Голосовой разговор идёт: подключается или говорят. Голосовое с очков сюда не относится — у него нет экрана.
    var isConversation: Bool {
        switch self {
        case .connecting, .talking: true
        default: false
        }
    }
}

/// Микрофон очков не пошёл. [askPermission] — он не разрешён в Meta AI: предложить разрешить.
/// [canUsePhone] — это был разговор: его можно продолжить с микрофона телефона.
struct GlassesMicrophoneHelp: Equatable {
    let askPermission: Bool
    let canUsePhone: Bool
}

/// Распознанный вопрос пользователя во время разговора; [final] — фраза закончена и уже ушла агенту.
struct HeardText: Equatable {
    let text: String
    let final: Bool
}

extension Optional where Wrapped == HeardText {
    /// Строка после нового распознанного [text]: он заменяет прежнюю целиком. Пустой — сказанное оказалось не Канату:
    /// незаконченная фраза исчезает, а заданный вопрос остаётся.
    func next(_ text: String, final: Bool) -> HeardText? {
        if !text.isEmpty { return HeardText(text: text, final: final) }
        if self?.final == true { return self }
        return nil
    }
}

/// Команда с очков не выполнена, а экрана голоса перед глазами нет — без уведомления пользователь услышал бы только
/// сигнал сбоя.
struct HandsFreeFailureNotice: Equatable {
    let messageKey: String
    let allowInMetaAi: Bool
    let continueOnPhone: Bool
}

/// Куда пойдёт видео, которое начинают снимать кнопкой очков.
enum VideoSlot {
    /// Команды нет — видео только в галерею.
    case gallery
    /// К голосовому видео уже есть, а больше одного сервер не примет: не снимаем, пользователь услышит отказ.
    case taken
    /// Видео — команде, во время которой его начали снимать. [ownCamera] — команда камеру очков не включает.
    case forCommand(VideoReservation, ownCamera: Bool)
}

/// Место для видео в команде — голосовом или разговоре. Снявший видео загружает его, пока оно нужно ([isWanted]),
/// и отдаёт команде UUID ([complete]) или сообщает, что видео не будет ([fail]) — ровно одно из двух.
final class VideoReservation: @unchecked Sendable {
    private let ended: ResultBox<Void>
    private let id: ResultBox<String>
    private let deliver: (String) -> Bool

    init(ended: ResultBox<Void>, id: ResultBox<String>, deliver: @escaping (String) -> Bool) {
        self.ended = ended
        self.id = id
        self.deliver = deliver
    }

    /// Возвращается, когда команда кончилась (голосовое записано, разговор закрыт): запись пора остановить.
    func awaitCommandEnd() async { await ended.wait() }

    /// Видео ещё ждут: голосовое не ушло или разговор идёт.
    var isWanted: Bool { !id.isDone }

    /// Команда уже кончилась: видео, начатое только сейчас, к ней не успеет.
    var isCommandOver: Bool { ended.isDone }

    /// Отдаёт UUID загруженного видео команде. false — команда его уже не ждёт.
    func complete(_ videoId: String) -> Bool { id.set(videoId) && deliver(videoId) }

    /// Видео не будет: не записалось, не загрузилось или стало не нужно.
    func fail() { id.set(nil) }
}

extension ResultBox {
    var isDone: Bool { isSet }
}

/// Голосовое управление с очков. Живёт, пока пользователь в приложении, а не только на экране голоса.
/// Кнопка камеры: клик + удержание — голосовое в чат (останавливает только двойное нажатие), двойное нажатие
/// из состояния покоя — разговор, тройное — следующая команда в новом чате. Одиночное нажатие снимает фото,
/// удержание — видео (съёмку ведёт фича glasses); куда они уйдут, решают [reservePhoto] и [reserveVideo].
@MainActor
@Observable
final class HandsFreeVoice {
    private(set) var state: VoiceUiState = .idle
    private(set) var muted = false {
        didSet { mutedFlag.value = muted }
    }
    /// То же «без звука» для потока микрофона: его читают не на главном потоке.
    @ObservationIgnored private let mutedFlag = Locked(false)
    /// Ход работы Каната над ответом в разговоре, пока ответ не сохранён; nil — сейчас он не работает.
    private(set) var liveTrace: LiveTrace?
    /// Номер последнего начатого разговора (0 — разговоров ещё не было).
    private(set) var conversation = 0
    /// Сбой команды, о котором нужно уведомить: экрана голоса в этот момент не видно.
    var failureNotice: HandsFreeFailureNotice?

    /// id чата разговора, в историю которого сервер только что сохранил вопрос или ответ.
    @ObservationIgnored let chatChanges = PassthroughSubject<String, Never>()

    /// Экран голоса на виду — ошибку пользователь видит и без уведомления.
    @ObservationIgnored var voiceScreenVisible = false
    /// На экране проверка очков: жесты распознаёт она, а сами они ничего не запускают.
    @ObservationIgnored var isPracticing = false

    @ObservationIgnored private let repository: VoiceRepository
    @ObservationIgnored private let glasses: GlassesControls
    @ObservationIgnored private let chat: HandsFreeChat
    @ObservationIgnored private var command: Task<Void, Never>?
    @ObservationIgnored private var commandEnded = ResultBox<Void>()
    @ObservationIgnored private var noteStop = ResultBox<Void>()
    /// Снимки к текущему голосовому — у каждого голосового свой список.
    @ObservationIgnored private var notePhotos: [ResultBox<String>] = []
    /// «Вот, смотри» текущего разговора: копятся, пока сокет переподключается.
    @ObservationIgnored private var callPhotos = AsyncQueue<String>()
    /// Видео к текущему голосовому — у каждого голосового своё.
    @ObservationIgnored private var noteVideo = NoteVideo()
    @ObservationIgnored private var callVideos = AsyncQueue<String>()
    /// Видео разговора, которые ещё снимаются или грузятся: пока они есть, разговор не кончается по тишине.
    @ObservationIgnored private var callVideosPending = Locked(0)
    /// Текущий разговор идёт с микрофона телефона — камеру очков он не включает.
    @ObservationIgnored private var callOnPhone = false
    /// Чат последнего разговора; nil — разговоров не было, его чат ещё не создан или его удалили.
    @ObservationIgnored private var conversationChat: String?

    /// Больше снимков к одному голосовому сервер не принимает.
    private static let maxNotePhotos = 4
    private static let photoUploadTimeout: Double = 10
    /// Видео сначала сохраняется в галерею и только потом грузится — ждём чуть дольше самой загрузки.
    private static let noteVideoWait = videoUploadTimeoutSeconds + 10

    init(repository: VoiceRepository, glasses: GlassesControls, chat: HandsFreeChat) {
        self.repository = repository
        self.glasses = glasses
        self.chat = chat
    }

    /// Чат, в который пишет (или писал) последний разговор; nil — открыть нечего.
    func conversationChatId() -> String? { conversationChat }

    func toggleMute() {
        if state.isConversation { muted.toggle() }
    }

    /// Место для снимка с кнопки очков в текущей команде. Берётся в момент нажатия: иначе голосовое успело бы уйти
    /// без снимка. Вызывающий отдаёт в резерв id загруженного снимка или nil. nil — команды, которой нужен снимок, нет.
    func reservePhoto() -> ResultBox<String>? {
        switch state {
        case .recordingNote:
            guard notePhotos.count < Self.maxNotePhotos else { return nil }
            let reservation = ResultBox<String>()
            notePhotos.append(reservation)
            return reservation
        case .connecting, .talking:
            let photos = callPhotos
            let reservation = ResultBox<String>()
            Task {
                await reservation.wait()
                if let id = reservation.value { photos.send(id) }
            }
            return reservation
        default:
            return nil
        }
    }

    /// Куда пойдёт видео с кнопки очков, которое начинают снимать сейчас. Решается в момент удержания.
    func reserveVideo() -> VideoSlot {
        switch state {
        case .recordingNote:
            let video = noteVideo
            if video.isTaken { return .taken }
            let id = ResultBox<String>()
            video.id = id
            return .forCommand(VideoReservation(ended: video.recorded, id: id) { _ in true }, ownCamera: false)
        case .connecting, .talking:
            guard command != nil else { return .gallery }
            let videos = callVideos
            let ended = commandEnded
            let pending = callVideosPending
            let id = ResultBox<String>()
            pending.update { $0 += 1 }
            // Отдано, не вышло или разговор кончился — видео больше не держит разговор от выхода по тишине.
            Task {
                await id.wait()
                pending.update { $0 -= 1 }
            }
            // Разговор кончился — видео к нему загружать незачем.
            Task {
                await ended.wait()
                id.set(nil)
            }
            return .forCommand(
                VideoReservation(ended: ended, id: id) { videoId in !ended.isDone && videos.send(videoId) },
                ownCamera: callOnPhone
            )
        default:
            return .gallery
        }
    }

    /// Слушает кнопку очков, пока вызывающий не отменит.
    func listenToGlasses() async {
        for await gesture in glasses.captureButtonGestures.values {
            onGesture(gesture)
        }
    }

    /// Кнопка на экране начинает разговор, а во время команды завершает её. Запись голосового она, как и
    /// двойное нажатие на очках, останавливает и отправляет — иначе запись пропала бы.
    func toggleConversation() {
        if state == .recordingNote {
            noteStop.set(())
        } else if command != nil {
            stopCommand()
        } else {
            startConversation()
        }
    }

    /// «Завершить» в уведомлении или на панели: заканчивает только разговор.
    func endConversation() {
        if state.isConversation { stopCommand() }
    }

    /// Микрофон очков для разговора не пошёл, и пользователь выбрал продолжить с микрофона телефона.
    func continueWithPhoneMicrophone() {
        guard case .error(_, let help) = state, help?.canUsePhone == true else { return }
        startConversation(phoneMicrophone: true)
    }

    /// Ошибку прошлой команды пользователь увидел — снова покой. Идущую команду не трогает.
    func dismissError() {
        if case .error = state { state = .idle }
    }

    /// В голосовой режим перешли из чата [chatId] (nil — с экрана «Новый чат»): разговор пойдёт туда.
    func useChatOnScreen(_ chatId: String?) {
        guard command == nil else { return }
        chat.use(chatId)
    }

    /// Пользователь вышел: прерываем команду, а следующий вход начнётся с нового чата.
    func reset() {
        command?.cancel()
        command = nil
        state = .idle
        muted = false
        chat.startNew()
        conversationChat = nil
    }

    private func onGesture(_ gesture: GlassesGesture) {
        log.debug("Жест \(gesture) в состоянии \(state)")
        switch state {
        // Во время записи её завершает и отправляет только двойное нажатие; одиночное — снимок к ней, удержание — видео.
        case .recordingNote:
            if gesture == .doublePress { noteStop.set(()) }
        // Одиночное — снимок Канату, разговор и ответ останавливает только двойное.
        case .connecting, .talking, .answeringNote:
            if gesture == .doublePress { toggleConversation() }
        // Во время проверки очков жест нажимают по её просьбе, а не ради команды.
        case .idle, .error:
            guard !isPracticing else { return }
            switch gesture {
            // Простое удержание (без клика перед ним) запись не начинает.
            case .clickAndHold: startNote()
            case .doublePress: startConversation()
            case .triplePress:
                chat.startNew()
                Task { await repository.signal(.newChat) }
            case .singlePress, .hold: break
            }
        // Голосовое уже уходит — его не прерываем.
        case .sendingNote:
            break
        }
    }

    private func stopCommand() {
        let stopped = command
        stopped?.cancel()
        command = nil
        state = .idle
        muted = false
        // Отмена не проходит через успешную ветку — сигнал о выходе играем сами, когда команда закрыла микрофон.
        Task {
            await stopped?.value
            await repository.signal(.conversationEnded)
        }
    }

    private func startConversation(phoneMicrophone: Bool = false) {
        let photos = AsyncQueue<String>()
        let videos = AsyncQueue<String>()
        let pending = Locked(0)
        let mutedFlag = self.mutedFlag
        callPhotos = photos
        callVideos = videos
        callVideosPending = pending
        callOnPhone = phoneMicrophone
        conversationChat = nil
        conversation += 1
        runCommand(.connecting, onEnd: {
            // Разговор кончился как угодно: снимки и видео к нему больше не уходят.
            self.liveTrace = nil
            photos.finish()
            videos.finish()
        }) {
            self.muted = false
            let chatId = try await self.chat.current()
            self.conversationChat = chatId
            var request = ConversationRequest(chatId: chatId)
            request.muted = { mutedFlag.value }
            request.photoRequests = photos
            request.videoRequests = videos
            request.videoPending = { pending.value > 0 }
            request.onReady = { [weak self] in Task { @MainActor in self?.state = .talking(subtitle: nil, heard: nil, kanat: .listening) } }
            // Приходит с потока плеера — не должен вернуть talking, если разговор уже закончили.
            request.onSubtitle = { [weak self] text in
                Task { @MainActor in
                    guard let self, case .talking(_, let heard, let kanat) = self.state else { return }
                    self.state = .talking(subtitle: text, heard: heard, kanat: kanat)
                }
            }
            request.onHeard = { [weak self] text, final in
                Task { @MainActor in
                    guard let self, case .talking(let subtitle, let heard, let kanat) = self.state else { return }
                    self.state = .talking(subtitle: subtitle, heard: heard.next(text, final: final), kanat: kanat)
                }
            }
            request.phoneMicrophone = phoneMicrophone
            request.onEvent = { [weak self] event in Task { @MainActor in self?.onConversationEvent(chatId, event) } }
            try await self.repository.converse(request)
            // Разговор закрыл сервер или минута тишины; микрофон к этому времени уже закрыт.
            await self.repository.signal(.conversationEnded)
        }
    }

    private func onConversationEvent(_ chatId: String, _ event: ConversationEvent) {
        switch event {
        case .kanat(let activity):
            if case .talking(let subtitle, let heard, _) = state { state = .talking(subtitle: subtitle, heard: heard, kanat: activity) }
        case .saved(let answer):
            // Ответ сохранён — его ход работы теперь у самого сообщения в чате.
            if answer { liveTrace = nil }
            chatChanges.send(chatId)
        case .trace(let step):
            let steps = liveTrace?.chatId == chatId ? liveTrace!.steps : []
            liveTrace = LiveTrace(chatId: chatId, steps: steps + [step])
        // Снимок или видео дошли до Каната — теперь о них можно спрашивать.
        case .attached:
            Task { await repository.signal(.attached) }
        }
    }

    private func startNote() {
        var photos: [ResultBox<String>] = []
        notePhotos = photos
        let video = NoteVideo()
        noteVideo = video
        let stop = ResultBox<Void>()
        noteStop = stop
        runCommand(.recordingNote, onEnd: {
            // Голосовое кончилось как угодно: видео к нему не ждут.
            video.recorded.set(())
            video.id?.set(nil)
        }) {
            var note: URL?
            do {
                note = try await self.repository.recordNote(awaitStop: { await stop.wait() })
            } catch {
                video.id?.set(nil)
                video.recorded.set(())
                throw error
            }
            // Голосовое не записалось — его видео грузить незачем. Иначе видео пора остановить: отправка его ждёт.
            if note == nil { video.id?.set(nil) }
            video.recorded.set(())
            guard let note else { return }
            var sending = false
            defer { if !sending { try? FileManager.default.removeItem(at: note) } }
            self.state = .sendingNote
            // Сначала видео — оно грузится дольше всего, снимки за это время тоже успевают.
            let videoId = await self.awaitUploaded(video)
            photos = self.notePhotos
            let photoIds = await Self.awaitUploaded(photos)
            let chatId = try await self.chat.current()
            sending = true
            try await self.repository.sendNote(chatId: chatId, note: note, photoIds: photoIds, videoId: videoId) {
                await MainActor.run {
                    self.state = .answeringNote
                    self.chatChanges.send(chatId)
                }
                await self.repository.signal(.noteSent)
            }
        }
    }

    /// UUID видео к голосовому; nil — его не снимали, оно не загрузилось или не успело. Не успело — голосовое уходит
    /// без него: сигнал сбоя скажет, что видео Канат не увидит.
    private func awaitUploaded(_ video: NoteVideo) async -> String? {
        guard let id = video.id else { return nil }
        let done = await withTimeout(seconds: Self.noteVideoWait) { await id.wait(); return true }
        if done == nil {
            id.set(nil)
            log.warning("Видео к голосовому не загрузилось вовремя — голосовое уйдёт без него")
            await repository.signal(.failed)
            return nil
        }
        return id.value
    }

    /// Снимки, загрузка которых не уложилась в таймаут, к голосовому не прикладываем — оно важнее.
    private static func awaitUploaded(_ photos: [ResultBox<String>]) async -> [String] {
        _ = await withTimeout(seconds: photoUploadTimeout) {
            for photo in photos { await photo.wait() }
            return true
        }
        return photos.compactMap { $0.isDone ? $0.value : nil }
    }

    private func runCommand(_ initial: VoiceUiState, onEnd: @escaping () -> Void, block: @escaping () async throws -> Void) {
        let previous = command
        state = initial
        let ended = ResultBox<Void>()
        commandEnded = ended
        command = Task {
            // Отменённая команда ещё освобождает звуковой канал — новая должна поднять его уже после.
            previous?.cancel()
            await previous?.value
            defer {
                muted = false
                chat.touch()
                ended.set(())
                onEnd()
            }
            do {
                try await block()
                if !Task.isCancelled { state = .idle }
            } catch is CancellationError {
                return
            } catch let error as VoiceError {
                guard !Task.isCancelled else { return }
                log.warning("Команда с очков не выполнена: \(error)")
                // Чат удалили в другом месте — следующая команда начнёт новый, а не упрётся в тот же.
                if error == .chatNotFound {
                    chat.startNew()
                    conversationChat = nil
                }
                let help: GlassesMicrophoneHelp? = if case .glassesMicrophoneUnavailable = error {
                    GlassesMicrophoneHelp(askPermission: error.noPermission, canUsePhone: initial == .connecting)
                } else {
                    nil
                }
                state = await failed(.error(messageKey: Self.messageKey(error), glassesMicrophone: help))
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Команда с очков упала: \(error)")
                state = await failed(.error(messageKey: "voice_error_server", glassesMicrophone: nil))
            }
            if command == nil || Task.isCancelled { return }
            command = nil
        }
    }

    /// Сигнал сбоя, а если экрана голоса не видно — и уведомление с причиной.
    private func failed(_ error: VoiceUiState) async -> VoiceUiState {
        if !voiceScreenVisible, case .error(let key, let help) = error {
            failureNotice = HandsFreeFailureNotice(messageKey: key, allowInMetaAi: help?.askPermission == true, continueOnPhone: help?.canUsePhone == true)
        }
        await repository.signal(.failed)
        return error
    }

    private static func messageKey(_ error: VoiceError) -> String {
        switch error {
        case .glassesDisconnected: "voice_error_glasses_disconnected"
        case .glassesTakenOff: "voice_error_glasses_taken_off"
        case .microphoneUnavailable: "voice_error_microphone"
        case .phoneMicrophoneInBackground: "voice_error_phone_mic_background"
        case .glassesMicrophoneUnavailable(.noPermission): "voice_error_glasses_mic_permission"
        case .glassesMicrophoneUnavailable(.cameraBusy): "voice_error_glasses_camera_busy"
        case .glassesMicrophoneUnavailable(.failed): "voice_error_glasses_mic_failed"
        case .notAllowed: "voice_error_not_allowed"
        case .notSignedIn: "voice_error_not_signed_in"
        case .chatNotFound: "voice_error_chat_not_found"
        case .tooManyConversations: "voice_error_too_many_conversations"
        case .kanatUnavailable: "voice_error_kanat_unavailable"
        case .network: "voice_error_network"
        case .server: "voice_error_server"
        }
    }

    /// Видео к одному голосовому: больше одного к вопросу сервер не принимает.
    private final class NoteVideo {
        /// Голосовое записано или сорвалось: видео к нему пора остановить.
        let recorded = ResultBox<Void>()
        var id: ResultBox<String>?

        /// Место занято, пока видео снимается, загружается или уже загружено; не снялось — свободно.
        var isTaken: Bool {
            guard let id else { return false }
            return !id.isDone || id.value != nil
        }
    }
}

private let log = Log("HandsFreeVoice")
