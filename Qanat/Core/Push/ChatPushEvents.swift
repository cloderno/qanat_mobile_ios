import Combine
import Foundation

/// Push «Канат ответил», пока приложение открыто: видимый экран чата сразу перечитывает чат, а не ждёт очередного
/// опроса. Если ответ так появился в открытом чате, системное уведомление о нём не нужно.
final class ChatPushEvents {
    private let subject = PassthroughSubject<AnsweredPush, Never>()
    private var subscribers = 0
    private let lock = NSLock()

    /// Чат, который сейчас виден на экране; nil — экран чата не виден или открыт новый чат.
    var openChatId: String? {
        get { lock.withLock { _openChatId } }
        set { lock.withLock { _openChatId = newValue } }
    }
    private var _openChatId: String?

    /// Push о чатах, в которых агент только что ответил. Слушает только видимый экран чата.
    func answered() -> AsyncStream<AnsweredPush> {
        AsyncStream { continuation in
            lock.withLock { subscribers += 1 }
            let cancellable = subject.sink { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                cancellable.cancel()
                self?.lock.withLock { self?.subscribers -= 1 }
            }
        }
    }

    /// Передаёт push экрану чата. true — push про открытый на экране чат и ответ уже показан в ленте:
    /// уведомление не нужно. Ждёт не дольше 10 с; push о других чатах не ждёт вовсе.
    func deliver(chatId: String) async -> Bool {
        guard lock.withLock({ subscribers }) > 0 else { return false }
        let push = AnsweredPush(chatId: chatId)
        subject.send(push)
        guard chatId == openChatId else { return false }
        return await withTimeout(seconds: 10) { await push.shownInFeed() } ?? false
    }
}

/// Push об ответе в чате [chatId]; экран отмечает, показал ли он ответ в ленте.
final class AnsweredPush {
    let chatId: String
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private let lock = NSLock()

    init(chatId: String) {
        self.chatId = chatId
    }

    func handled(shownInFeed: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = shownInFeed
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: shownInFeed)
    }

    fileprivate func shownInFeed() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Чат, о котором push: `chat_uuid` в data, у старых push — только ссылка "/app/assistant?chat=<uuid>".
/// nil — push не про ответ агента.
func pushChatId(_ data: [AnyHashable: Any]) -> String? {
    if let id = data["chat_uuid"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty { return id }
    guard let link = data["link"] as? String else { return nil }
    return chatIdFromAssistantLink(link)
}

/// "/app/assistant?chat=<uuid>" → uuid; другие ссылки — nil.
func chatIdFromAssistantLink(_ link: String) -> String? {
    guard let components = URLComponents(string: link), components.path.hasPrefix("/app/assistant") else { return nil }
    let id = components.queryItems?.first { $0.name == "chat" }?.value
    return id?.isEmpty == false ? id : nil
}
