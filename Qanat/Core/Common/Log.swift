import OSLog

/// Логгер с категорией — как TAG в Android-версии. debug пишется только в debug-сборке.
struct Log {
    private let logger: Logger

    init(_ category: String) {
        logger = Logger(subsystem: "com.rating.qanatmobile", category: category)
    }

    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
