import Foundation

/// Результат [operation], или nil — если она не успела за [seconds] или бросила. Как withTimeoutOrNull в Kotlin,
/// но и ошибку превращает в nil: зовут там, где важен только факт ответа.
func withTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Результат [operation], или nil — если не успела за [seconds]. Ошибки operation пробрасываются.
func withThrowingTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Значение, которое читают и пишут с разных потоков.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func update(_ transform: (inout T) -> Void) {
        lock.withLock { transform(&stored) }
    }
}

/// Монотонные миллисекунды — как SystemClock.elapsedRealtime на Android.
func uptimeMs() -> Int64 {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
}
