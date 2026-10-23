import Foundation

/// Жест кнопкой камеры на очках, собранный из отдельных нажатий.
enum GlassesGesture: Equatable { case singlePress, doublePress, triplePress, hold, clickAndHold }

/// Нажатие кнопки камеры в том виде, как его отдаёт прошивка очков.
enum CapturePress: Equatable { case short, double, hold }

/// Прошивка различает только короткое, двойное нажатие и удержание, и каждое приходит одним событием — когда кнопку
/// отпустили. Тройного нет, поэтому нажатия считаем сами: жест закончен, когда в своё окно не пришло следующее.
///
/// На живых очках DOUBLE приходит ВМЕСТЕ с SHORT на тот же физический тап: прошивка шлёт SHORT, SHORT, DOUBLE на одно
/// двойное нажатие. Поэтому DOUBLE только подтверждает счётчик до минимума 2, а DOUBLE, отставший от уже выданного
/// жеста, — эхо этого жеста. Удержание вскоре после клика, уже ставшего SINGLE_PRESS, — всё равно клик + удержание.
final class GestureRecognizer {
    // ПРЕДПОЛОЖЕНИЕ: окна не замерены на очках — времена нажатий пишутся в лог, подгонять по ним.
    static let singlePressWindowMs: Int64 = 850
    /// Сколько ждать третьего нажатия после второго.
    static let tripleTapWindowMs: Int64 = 450
    /// Удержание, пришедшее так скоро после клика, — клик + удержание, даже если клик уже стал SINGLE_PRESS.
    static let lateClickAndHoldMs: Int64 = 1_500
    /// DOUBLE без новых нажатий так скоро после выданного жеста — эхо этого жеста от прошивки.
    static let trailingDoubleMs: Int64 = 500

    private let now: () -> Int64
    private var taps = 0
    private var lastShortAt = Int64.min / 2
    private var resolvedClickAt = Int64.min / 2
    private var lastGestureAt = Int64.min / 2

    init(now: @escaping () -> Int64 = uptimeMs) {
        self.now = now
    }

    /// Сколько ждать следующего нажатия, прежде чем выдать накопленный жест; nil — ждать нечего.
    var pendingWindowMs: Int64? {
        switch taps {
        case 0: nil
        case 1: Self.singlePressWindowMs
        default: Self.tripleTapWindowMs
        }
    }

    /// Окно ожидания истекло: накопленные нажатия — одинарное или двойное.
    func timeout() -> GlassesGesture? {
        guard taps > 0 else { return nil }
        return emit(taps == 1 ? .singlePress : .doublePress)
    }

    /// Пришло нажатие. Возвращает жест, если он уже закончен.
    func press(_ press: CapturePress) -> GlassesGesture? {
        switch press {
        case .hold:
            let clicked = taps > 0 || now() - resolvedClickAt < Self.lateClickAndHoldMs
            return emit(clicked ? .clickAndHold : .hold)
        case .double:
            if taps > 0 || now() - lastGestureAt >= Self.trailingDoubleMs { taps = max(taps, 2) }
        case .short:
            taps += 1
            lastShortAt = now()
        }
        return taps >= 3 ? emit(.triplePress) : nil
    }

    private func emit(_ gesture: GlassesGesture) -> GlassesGesture {
        resolvedClickAt = gesture == .singlePress ? lastShortAt : Int64.min / 2
        taps = 0
        lastGestureAt = now()
        return gesture
    }
}

extension AsyncStream where Element == CapturePress {
    /// Нажатия → жесты: окна ожидания и нажатия обрабатываются строго по очереди в одной задаче.
    func gestures() -> AsyncStream<GlassesGesture> {
        let presses = AsyncQueue<CapturePress>()
        return AsyncStream { continuation in
            let feeder = Task {
                for await press in self { presses.send(press) }
                presses.finish()
            }
            let worker = Task {
                let recognizer = GestureRecognizer()
                var windowStartedAt = uptimeMs()
                while !Task.isCancelled {
                    if let window = recognizer.pendingWindowMs {
                        // Ждём следующее нажатие опросом очереди: отменять чтение нельзя — взятое нажатие пропало бы.
                        if let press = presses.tryNext() {
                            if let gesture = recognizer.press(press) { continuation.yield(gesture) }
                            windowStartedAt = uptimeMs()
                        } else if uptimeMs() - windowStartedAt >= window {
                            if let gesture = recognizer.timeout() { continuation.yield(gesture) }
                        } else if presses.isFinished {
                            break
                        } else {
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    } else {
                        guard let press = try? await presses.next() else { break }
                        if let gesture = recognizer.press(press) { continuation.yield(gesture) }
                        windowStartedAt = uptimeMs()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                feeder.cancel()
                worker.cancel()
            }
        }
    }
}
