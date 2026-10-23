import Foundation

/// Неограниченная очередь между потоками — как Channel(UNLIMITED) в Kotlin: пишут без ожидания, читатель ждёт
/// следующего. В отличие от AsyncStream, недочитанное можно выбросить ([clearPending]) — так сокет сбрасывает хвост
/// ответа, когда пользователь перебил Каната. Закрывается штатно ([finish]) или с ошибкой.
final class AsyncQueue<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Element] = []
    private var waiter: CheckedContinuation<Element?, Error>?
    private var finished = false
    private var failure: Error?

    init() {}

    /// false — очередь уже закрыта, элемент не принят.
    @discardableResult
    func send(_ element: Element) -> Bool {
        let resumed: CheckedContinuation<Element?, Error>? = lock.withLock {
            guard !finished else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            buffer.append(element)
            return nil
        }
        if let resumed {
            resumed.resume(returning: element)
            return true
        }
        return lock.withLock { !finished }
    }

    /// Следующий элемент; nil — очередь закрыта штатно и прочитана. Закрытая с ошибкой бросает её, отдав прочее.
    func next() async throws -> Element? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, Error>) in
                lock.lock()
                if !buffer.isEmpty {
                    let element = buffer.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: element)
                } else if finished {
                    let error = failure
                    lock.unlock()
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Element?, Error>? = lock.withLock {
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Элемент, если он уже есть; иначе nil без ожидания.
    func tryNext() -> Element? {
        lock.withLock { buffer.isEmpty ? nil : buffer.removeFirst() }
    }

    /// Выбрасывает всё, что ещё не прочитали.
    func clearPending() {
        lock.withLock { buffer.removeAll() }
    }

    var isFinished: Bool { lock.withLock { finished } }

    func finish(throwing error: Error? = nil) {
        let waiting: CheckedContinuation<Element?, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            failure = error
            defer { waiter = nil }
            return waiter
        }
        if let waiting {
            if let error { waiting.resume(throwing: error) } else { waiting.resume(returning: nil) }
        }
    }

    /// Очередь как AsyncSequence — для `for try await`.
    var elements: AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream(unfolding: { try await self.next() })
    }
}
