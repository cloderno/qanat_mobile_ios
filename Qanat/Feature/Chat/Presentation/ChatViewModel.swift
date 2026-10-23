import Combine
import Foundation
import UIKit

@MainActor
@Observable
final class ChatViewModel {
    private(set) var state = ChatUiState()

    private let repository: ChatRepository
    private let voiceRecorder: VoiceNoteRecorder
    private let voicePlayer: VoicePlayer
    private let profileRepository: ProfileRepository
    private let photos: PhotoRepository
    private let preferencesStorage: PreferencesStorage
    private let documents: DocumentRepository
    private let pushEvents: ChatPushEvents

    private var chatsCursor: String?
    private var hasMoreChats = true
    private var chatsTask: Task<Void, Never>?
    private var chatsGeneration = 0
    private var earlierTask: Task<Void, Never>?
    /// Открытие чата или ответ в нём; переход в другой чат его отменяет.
    private var chatTask: Task<Void, Never>?
    /// Свои вопросы, которые уходят или чей ответ ещё идёт потоком: фоновая сверка их не трогает.
    private var answersInFlight = 0
    /// Поток ответа оборвался без "done" после того, как вопрос сохранён, — сервер ответ допишет: «печатает…» висит,
    /// пока ответ не появится при сверке, но не дольше [orphanedAnswerTimeout].
    private var orphanedAnswerWait: Task<Void, Never>?
    /// Сверки с сервером (опрос, возврат на экран, push) идут по одной.
    private var syncing = false
    private var subscriptions = Set<AnyCancellable>()

    private static let voiceReply = "voice"
    /// Запасная сверка, если поток событий сервера недоступен; обычно изменения приходят им сразу.
    private static let syncInterval: Double = 30
    private static let orphanedAnswerDelay: Double = 2
    /// Дольше ~2 минут сервер ответ не пишет.
    private static let orphanedAnswerTimeout: Double = 120

    init(
        repository: ChatRepository,
        voiceRecorder: VoiceNoteRecorder,
        voicePlayer: VoicePlayer,
        profileRepository: ProfileRepository,
        glassesControls: GlassesControls,
        photos: PhotoRepository,
        preferencesStorage: PreferencesStorage,
        documents: DocumentRepository,
        pushEvents: ChatPushEvents
    ) {
        self.repository = repository
        self.voiceRecorder = voiceRecorder
        self.voicePlayer = voicePlayer
        self.profileRepository = profileRepository
        self.photos = photos
        self.preferencesStorage = preferencesStorage
        self.documents = documents
        self.pushEvents = pushEvents

        refreshChats()
        voicePlayer.playing.receive(on: DispatchQueue.main).sink { [weak self] in self?.state.playing = $0 }.store(in: &subscriptions)
        glassesControls.deviceInfo.receive(on: DispatchQueue.main).sink { [weak self] in self?.state.glassesInfo = $0 }.store(in: &subscriptions)
        repository.chatUpdates.receive(on: DispatchQueue.main).sink { [weak self] updatedId in
            guard let self else { return }
            // Не перезагружаем поверх активного стрима ответа, запущенного из самого экрана.
            guard state.answer == nil else { return }
            if state.chat == nil || state.chat?.id == updatedId {
                Task { await self.load(updatedId) }
            }
            refreshChats()
        }.store(in: &subscriptions)
        Task { await loadProfile() }
    }

    /// Без профиля шторка показывает «Настройки» вместо имени, а приветствие — без обращения.
    private func loadProfile() async {
        guard let profile = try? await profileRepository.get() else {
            log.warning("Профиль для шторки не загружен")
            return
        }
        let name = [profile.firstName, profile.lastName].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        let second = profile.middleName.trimmingCharacters(in: .whitespaces).isEmpty ? profile.lastName : profile.middleName
        state.profileName = name.isEmpty ? nil : name
        state.profileInitials = [profile.firstName, second].compactMap { $0.trimmingCharacters(in: .whitespaces).first?.uppercased() }.joined()
        state.profileAvatarURL = profile.avatarURL
        // Как обращается сам агент: по имени и отчеству, без отчества — по имени.
        if !profile.firstName.trimmingCharacters(in: .whitespaces).isEmpty {
            state.greetingName = [profile.firstName, profile.middleName].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        }
    }

    /// Пока экран чата виден: по событиям сервера «чат изменился», по push «Канат ответил» и на всякий случай
    /// раз в [syncInterval] сверяемся с сервером. Экран зовёт это в `.task` — уход с экрана всё прекращает.
    /// [chatChanges] — id чатов, в которые только что что-то записали мимо экрана (голосовой разговор).
    func keepInSync(chatChanges: AsyncStream<String>?) async {
        pushEvents.openChatId = state.chat?.id
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await push in self.pushEvents.answered() { await self.onAnsweredPush(push) }
            }
            if let chatChanges {
                group.addTask { @MainActor in
                    for await id in chatChanges { _ = await self.syncWithServer(rereadOpenChat: self.state.chat?.id == id) }
                }
            }
            // Вопрос, ответ и шаги работы на сервере с любого устройства.
            group.addTask { @MainActor in
                for await event in self.repository.serverChatEvents() { await self.onServerChatEvent(event) }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.syncInterval))
                    if Task.isCancelled { break }
                    _ = await self.syncWithServer(rereadOpenChat: false)
                }
            }
            await group.waitForAll()
        }
        pushEvents.openChatId = nil
        // Ушли с экрана — событий о чужом ответе больше не услышим, «Работаю…» не оставляем.
        state.remoteWork = nil
    }

    /// Свой вопрос, пока идёт его поток, сверку не запускает, и его шаги приходят в самом ответе — здесь их пропускаем.
    /// Чужой вопрос в открытом чате — «Работаю…» и шаги до ответа; на шаг чат не перечитываем.
    private func onServerChatEvent(_ event: ServerChatEvent) async {
        let own = answersInFlight > 0
        switch event {
        case .trace(let chatId, let step):
            if !own && state.chat?.id == chatId {
                let steps = state.remoteWork?.chatId == chatId ? state.remoteWork!.steps : []
                state.remoteWork = LiveTrace(chatId: chatId, steps: steps + [step])
            }
        case .changed(let chatId, let answered):
            if answered {
                if state.remoteWork?.chatId == chatId { state.remoteWork = nil }
            } else if !own && state.chat?.id == chatId {
                state.remoteWork = LiveTrace(chatId: chatId, steps: [])
            }
            _ = await syncWithServer(rereadOpenChat: state.chat?.id == chatId)
        }
    }

    /// Push про ответ: открытый чат перечитываем сразу и говорим, удалось ли показать ответ в ленте.
    private func onAnsweredPush(_ push: AnsweredPush) async {
        let isOpen = state.chat?.id == push.chatId
        let shown = await syncWithServer(rereadOpenChat: isOpen) && isOpen && state.chat?.id == push.chatId
        push.handled(shownInFeed: shown)
    }

    /// Вернулись на экран чата: список и открытый чат могли измениться, пока нас не было.
    func onScreenResumed() {
        Task { _ = await syncWithServer(rereadOpenChat: true) }
    }

    /// Тихая сверка: первая пачка списка чатов и закреплённые, а открытый чат — если он изменился на сервере
    /// (или [rereadOpenChat]). Без индикаторов загрузки; ошибки только в лог. Возвращает: открытый чат перечитан.
    private func syncWithServer(rereadOpenChat: Bool) async -> Bool {
        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
        syncing = true
        defer { syncing = false }
        guard state.shouldSyncInBackground(answerInFlight: answersInFlight > 0) else { return false }
        let listed = await syncChatList()
        guard let open = state.chat else { return false }
        let fresh = listed.first { $0.id == open.id }
        let changed = fresh != nil && fresh?.updatedAt != open.updatedAt
        return rereadOpenChat || changed || awaitingOrphanedAnswer ? await rereadLatest(open.id) : false
    }

    /// Свежие чаты списка — по ним видно, изменился ли открытый; пусто, если не загрузились.
    private func syncChatList() async -> [Chat] {
        // Список уже перечитывается (потянули шторку, старт) — второй запрос не нужен.
        if chatsTask != nil { return [] }
        let before = state.chats
        do {
            let pinned = try await repository.pinnedChats()
            let page = try await repository.chats(cursor: nil)
            // Пока ждали, список поменялся здесь же или пошёл свой вопрос — ответ сервера мог устареть.
            if answersInFlight > 0 || state.chats != before { return [] }
            let hasMore = page.nextCursor != nil
            let merged = mergeFirstChatPage(current: state.chats, firstPage: page.chats, hasMore: hasMore)
            // Догруженные прокруткой чаты остались — курсор по-прежнему после них.
            if merged.count == page.chats.count {
                chatsCursor = page.nextCursor
                hasMoreChats = hasMore
            }
            state.chats = merged
            state.pinnedChats = pinned
            return pinned + page.chats
        } catch {
            log.warning("Список чатов в фоне не обновился: \(error)")
            return []
        }
    }

    /// Последние сообщения чата [id] поверх ленты — без спиннера и без сброса прокрутки. Возвращает: лента обновлена.
    private func rereadLatest(_ id: String) async -> Bool {
        let opened: OpenedChat
        do {
            opened = try await repository.openChat(id: id)
        } catch {
            log.warning("Чат \(id) в фоне не обновился: \(error)")
            return false
        }
        // Пока ждали сервер, открыли другой чат, задали новый вопрос или потянули ленту — эти данные уже не к месту.
        guard state.chat?.id == id, state.shouldSyncInBackground(answerInFlight: answersInFlight > 0) else { return false }
        let merged = mergeLatestMessages(current: state.messages, currentHasEarlier: state.hasEarlier, latest: opened.history)
        var next = state
        if awaitingOrphanedAnswer && merged.endsWithAnswer {
            // Ответ дописан: «печатает…» убираем.
            stopAwaitingOrphanedAnswer()
            next.answer = nil
        }
        next.messages = merged.messages
        next.hasEarlier = merged.hasEarlier
        state = next.withUpdatedChat(opened.chat)
        return true
    }

    /// Потянули шторку со списком чатов — принудительно перечитываем список с начала.
    func onRefreshChats() async {
        guard !state.isRefreshingChats else { return }
        state.isRefreshingChats = true
        refreshChats()
        await chatsTask?.value
        state.isRefreshingChats = false
    }

    private func refreshChats() {
        chatsTask?.cancel()
        chatsGeneration += 1
        let generation = chatsGeneration
        chatsTask = Task {
            // Отменённая задача не обнуляет ссылку на новую, запущенную вместо неё.
            defer { if chatsGeneration == generation { chatsTask = nil } }
            do {
                chatsCursor = nil
                let pinned = try await repository.pinnedChats()
                let page = try await repository.chats(cursor: nil)
                guard !Task.isCancelled else { return }
                chatsCursor = page.nextCursor
                hasMoreChats = page.nextCursor != nil
                state.chats = page.chats
                state.pinnedChats = pinned
            } catch {
                if !Task.isCancelled { showError(error) }
            }
        }
    }

    /// Потянули список сообщений открытого чата — принудительно перечитываем его с сервера.
    func onRefreshChat() async {
        guard let chat = state.chat, !state.isOpening, !state.isRefreshingMessages, state.answer == nil else { return }
        state.isRefreshingMessages = true
        await load(chat.id)
        state.isRefreshingMessages = false
    }

    func loadMoreChats() {
        guard chatsTask == nil, hasMoreChats else { return }
        chatsGeneration += 1
        let generation = chatsGeneration
        chatsTask = Task {
            defer { if chatsGeneration == generation { chatsTask = nil } }
            do {
                let page = try await repository.chats(cursor: chatsCursor)
                chatsCursor = page.nextCursor
                hasMoreChats = page.nextCursor != nil
                var seen = Set<String>()
                state.chats = (state.chats + page.chats).filter { seen.insert($0.id).inserted }
            } catch {
                showError(error)
            }
        }
    }

    func onNewChat() {
        chatTask?.cancel()
        stopAwaitingOrphanedAnswer()
        state.chat = nil
        state.messages = []
        state.hasEarlier = false
        state.isOpening = false
        state.answer = nil
        state.errorKey = nil
        pushEvents.openChatId = nil
    }

    func onOpenChat(_ id: String) {
        if state.chat?.id == id && state.answer == nil { return }
        chatTask?.cancel()
        stopAwaitingOrphanedAnswer()
        state.chat = state.chats.first { $0.id == id } ?? state.pinnedChats.first { $0.id == id }
        state.messages = []
        state.hasEarlier = false
        state.isOpening = true
        state.answer = nil
        state.errorKey = nil
        pushEvents.openChatId = id
        chatTask = Task { await load(id) }
        // Список — отдельно от chatTask: переход в следующий чат не должен его отменять.
        Task { _ = await syncChatList() }
    }

    /// Меню чата в шторке: закрепить или открепить.
    func onTogglePin(_ id: String) {
        guard let chat = (state.pinnedChats + state.chats).first(where: { $0.id == id }) else { return }
        updateChat { try await self.repository.setPinned(id: id, pinned: !chat.pinned) }
    }

    /// Меню чата в шторке: новое название; пустое не отправляем.
    func onRenameChat(_ id: String, title: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        updateChat { try await self.repository.rename(id: id, title: title) }
    }

    /// Меню чата в шторке, после подтверждения. Открытый чат закрывается — на его месте новый.
    func onDeleteChat(_ id: String) {
        Task {
            do {
                try await repository.deleteChat(id: id)
            } catch {
                showError(error)
                return
            }
            if state.chat?.id == id { onNewChat() }
            state.chats.removeAll { $0.id == id }
            state.pinnedChats.removeAll { $0.id == id }
        }
    }

    private func updateChat(_ request: @escaping () async throws -> Chat) {
        Task {
            do {
                state = state.withUpdatedChat(try await request())
            } catch {
                showError(error)
            }
        }
    }

    func onLoadEarlier() {
        guard let chat = state.chat, let first = state.messages.first, state.hasEarlier, earlierTask == nil else { return }
        earlierTask = Task {
            defer { earlierTask = nil }
            do {
                let history = try await repository.earlierMessages(chatId: chat.id, beforeMessageId: first.id)
                guard state.chat?.id == chat.id else { return }
                state.messages = history.messages + state.messages
                state.hasEarlier = history.hasEarlier
            } catch {
                showError(error)
            }
        }
    }

    func onInputChange(_ text: String) {
        state.input = text
        state.errorKey = nil
        state.noticeKey = nil
    }

    /// Подсказка на главном экране — сразу вопрос агенту, как будто его набрали и отправили.
    func onSuggestion(_ text: String) {
        guard state.answer == nil, state.voiceInput == .none else { return }
        state.input = text
        state.errorKey = nil
        onSend()
    }

    /// Снимок из выбора фото; новый заменяет прежний.
    func onPhotoPicked(_ image: UIImage) {
        state.attachedPhoto = image
        state.errorKey = nil
    }

    func onRemovePhoto() { state.attachedPhoto = nil }

    /// Готовое голосовое уходит вместо текста; набранный текст остаётся в поле. Снимок уходит с любым из них.
    func onSend() {
        guard state.canSend else { return }
        let current = state
        var voice: VoiceRecording?
        if case .ready(let recording) = current.voiceInput { voice = recording }
        let question = current.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = current.attachedPhoto
        if voice != nil { voicePlayer.stop() }

        let localQuestion = ChatMessage(
            id: localQuestionId,
            role: .user,
            text: voice != nil ? "" : question,
            hasAudio: voice != nil,
            photos: photo != nil ? [ChatPhoto(id: localPhotoId)] : []
        )
        if voice == nil { state.input = "" }
        state.voiceInput = .none
        state.attachedPhoto = nil
        state.messages.append(localQuestion)
        state.answer = PendingAnswer()
        state.errorKey = nil
        state.noticeKey = nil

        chatTask = Task {
            answersInFlight += 1
            var questionSaved = false
            var chatId = current.chat?.id
            // Чат, в котором поток ответа оборвался без "done": ответ возьмём из истории, когда сервер его допишет.
            var orphanedIn: String?
            do {
                // До создания чата: снимок, который не открылся, не должен оставить пустой чат на сервере.
                var photoIds: [String] = []
                if let photo {
                    guard let jpeg = photo.jpegData(compressionQuality: 0.95) else { throw ChatError.photoUnavailable }
                    photoIds = [try await photos.upload(jpeg: jpeg, source: .phone)]
                }
                let chat: Chat
                if let existing = current.chat {
                    chat = existing
                } else {
                    chat = try await repository.createChat()
                    state.chat = chat
                    state.chats.insert(chat, at: 0)
                    pushEvents.openChatId = chat.id
                }
                chatId = chat.id
                let answer: AsyncThrowingStream<AnswerEvent, Error>
                if let voice {
                    let reply = preferencesStorage.current().voiceReplyToNotes ? Self.voiceReply : nil
                    answer = repository.askByVoice(chatId: chat.id, recording: voice.file, reply: reply, photoIds: photoIds, videoId: nil)
                } else {
                    answer = repository.ask(chatId: chat.id, question: question, photoIds: photoIds)
                }
                for try await event in answer {
                    if case .questionSaved = event { questionSaved = true }
                    onAnswerEvent(event)
                    // Ответ на голосовое звучит или нет по своей настройке — вслух читаются только ответы на текст.
                    if case .done(let message, _) = event, voice == nil, let message { speakIfWanted(message) }
                }
                if state.answer != nil {
                    // Поток кончился без "done": сохранённый вопрос сервер допишет — ответ возьмём из истории.
                    // Несохранённый — как обрыв связи: вернём его в поле ввода.
                    if questionSaved { orphanedIn = chat.id } else { throw ChatError.network }
                }
            } catch is CancellationError {
                // Перешли в другой чат — ответ допишет сервер, его покажет история.
            } catch {
                let chatError = error as? ChatError ?? .server("\(error)")
                // Связь пропала, когда вопрос уже сохранён: сервер ответ допишет — ждём его, а не показываем ошибку.
                if questionSaved && chatError == .network {
                    log.warning("Поток ответа оборвался, ответ возьмём из истории")
                    orphanedIn = chatId
                } else {
                    state.answer = nil
                    state.messages.removeAll { $0.id == localQuestionId }
                    // Несохранённый вопрос возвращаем в поле ввода, чтобы его можно было отправить снова.
                    if !questionSaved {
                        if let voice { state.voiceInput = .ready(voice) } else { state.input = question }
                        if let photo { state.attachedPhoto = photo }
                    }
                    state.errorKey = Self.messageKey(chatError)
                }
            }
            answersInFlight -= 1
            // Сохранённая запись живёт на сервере, локальная копия больше не нужна.
            if questionSaved, let voice { try? FileManager.default.removeItem(at: voice.file) }
            if let orphanedIn { awaitOrphanedAnswer(orphanedIn) }
        }
    }

    private var awaitingOrphanedAnswer: Bool { orphanedAnswerWait != nil }

    /// Чуть ждём, пока сервер допишет ответ, и перечитываем чат; не дописал — дальше ждёт обычная сверка, но не дольше
    /// [orphanedAnswerTimeout]: потом «печатает…» убираем, чтобы не держать ввод.
    private func awaitOrphanedAnswer(_ chatId: String) {
        orphanedAnswerWait?.cancel()
        orphanedAnswerWait = Task {
            try? await Task.sleep(for: .seconds(Self.orphanedAnswerDelay))
            if Task.isCancelled { return }
            _ = await syncWithServer(rereadOpenChat: state.chat?.id == chatId)
            try? await Task.sleep(for: .seconds(Self.orphanedAnswerTimeout - Self.orphanedAnswerDelay))
            if Task.isCancelled { return }
            log.warning("Ответ в чате \(chatId) так и не появился — больше не ждём")
            if state.chat?.id == chatId && answersInFlight == 0 { state.answer = nil }
            orphanedAnswerWait = nil
        }
    }

    private func stopAwaitingOrphanedAnswer() {
        orphanedAnswerWait?.cancel()
        orphanedAnswerWait = nil
    }

    /// Разрешение на микрофон экран спрашивает до вызова.
    func onRecordStart() {
        guard state.voiceInput == .none else { return }
        do {
            try voiceRecorder.start()
            state.voiceInput = .recording
            state.errorKey = nil
        } catch {
            showError(error)
        }
    }

    func onRecordCancel() {
        guard state.voiceInput == .recording else { return }
        voiceRecorder.cancel()
        state.voiceInput = .none
    }

    func onRecordDone() {
        guard state.voiceInput == .recording else { return }
        state.voiceInput = voiceRecorder.stop().map { .ready($0) } ?? .none
    }

    var recordingLevel: Float { voiceRecorder.level }

    func onDeleteRecording() {
        guard case .ready(let recording) = state.voiceInput else { return }
        voicePlayer.stop()
        try? FileManager.default.removeItem(at: recording.file)
        state.voiceInput = .none
    }

    func onTogglePlayback(_ clip: VoiceClip) {
        Task { await voicePlayer.toggle(clip) }
    }

    /// JPEG снимка к вопросу: [thumbnail] — плитка в ленте, иначе весь снимок; nil — не загрузился.
    func loadPhoto(_ id: String, thumbnail: Bool) async -> Data? {
        do {
            return try await photos.photo(id: id, thumbnail: thumbnail)
        } catch {
            log.warning("Снимок \(id) не загрузился: \(error)")
            return nil
        }
    }

    /// Скачивает файл документа, затем экран его откроет. Пока качается один, нажатия не считаются.
    func onDownloadDocument(_ id: String) {
        guard state.downloadingDocument == nil else { return }
        state.downloadingDocument = id
        state.errorKey = nil
        Task {
            do {
                state.documentToOpen = try await documents.download(id: id, format: .docx)
            } catch {
                log.warning("Документ \(id) не скачался: \(error)")
                state.errorKey = "chat_document_download_failed"
            }
            state.downloadingDocument = nil
        }
    }

    /// Экран открыл скачанный файл.
    func onDocumentOpened() { state.documentToOpen = nil }

    /// Письмо из ответа — шаблоном [name]; то же название заменяет прежний шаблон.
    func onSaveLetterTemplate(documentId: String, name: String) {
        Task {
            do {
                _ = try await documents.saveAsTemplate(documentId: documentId, name: name)
                state.noticeKey = "letter_templates_saved"
                state.errorKey = nil
            } catch {
                log.warning("Письмо \(documentId) не сохранилось шаблоном: \(error)")
                state.errorKey = (error as? ChatError) == .notAllowed ? "chat_error_not_allowed" : "letter_templates_save_failed"
                state.noticeKey = nil
            }
        }
    }

    /// «Написать по шаблону»: новый чат, а в поле — начало просьбы, которое человек допишет.
    func onWriteFromTemplate(_ text: String) {
        onNewChat()
        state.input = text
        state.noticeKey = nil
        state.focusInput = true
    }

    /// Экран поставил курсор в поле ввода.
    func onInputFocused() { state.focusInput = false }

    func dismissMessage() {
        state.errorKey = nil
        state.noticeKey = nil
    }

    private func onAnswerEvent(_ event: AnswerEvent) {
        var answer = state.answer ?? PendingAnswer()
        switch event {
        case .questionSaved(let message):
            state.messages = state.messages.map { $0.id == localQuestionId ? message : $0 }
        case .transcribed(let message):
            // Расшифровка того же голосового, что в questionSaved: тот же id, теперь с текстом (или error).
            state.messages = state.messages.map { $0.id == message.id ? message : $0 }
        case .thinking(let text):
            answer.status = text
            state.answer = answer
        case .steps(let tools):
            answer.steps += tools
            state.answer = answer
        case .trace(let step):
            answer.trace.append(step)
            state.answer = answer
        case .textDelta(let text):
            answer.text += text
            state.answer = answer
        case .block(let block):
            answer.blocks.append(block)
            state.answer = answer
        case .speech:
            // Фразы голосового ответа звучат только в очках: в чате готовый ответ слушают плеером.
            break
        case .done(let message, let chat):
            state.answer = nil
            // nil — речь в голосовом вопросе не распознана: ответа агента не будет.
            if let message { state.messages.append(message) }
            state.chat = chat
            // Чат с новым ответом поднимается наверх списка, с названием от агента.
            state.chats = [chat] + state.chats.filter { $0.id != chat.id }
            // Закреплённый остаётся на своём месте, но с новым названием.
            state.pinnedChats = state.pinnedChats.map { $0.id == chat.id ? chat : $0 }
        }
    }

    private func speakIfWanted(_ answer: ChatMessage) {
        guard !answer.text.trimmingCharacters(in: .whitespaces).isEmpty, preferencesStorage.current().speakAnswers else { return }
        // Отдельно от chatTask: озвучка грузится секунды и не должна держать сам ответ.
        Task { await voicePlayer.toggle(.speech(messageId: answer.id, text: answer.text)) }
    }

    private func load(_ id: String) async {
        do {
            let opened = try await repository.openChat(id: id)
            guard !Task.isCancelled else { return }
            state.chat = opened.chat
            state.messages = opened.history.messages
            state.hasEarlier = opened.history.hasEarlier
            state.isOpening = false
            state.answer = nil
        } catch is CancellationError {
            return
        } catch {
            state.isOpening = false
            state.answer = nil
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        state.errorKey = Self.messageKey(error as? ChatError ?? .server("\(error)"))
    }

    static func messageKey(_ error: ChatError) -> String {
        switch error {
        case .notAllowed: "chat_error_not_allowed"
        case .notFound: "chat_error_not_found"
        case .microphoneUnavailable: "chat_error_microphone"
        case .photoUnavailable: "chat_error_photo"
        case .network: "chat_error_network"
        case .server: "chat_error_server"
        }
    }

    func onDisappear() {
        voicePlayer.stop()
    }
}

private let log = Log("ChatViewModel")
