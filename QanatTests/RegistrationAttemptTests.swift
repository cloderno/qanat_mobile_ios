import XCTest
@testable import Qanat

final class RegistrationAttemptTests: XCTestCase {
    func testStartOpensMetaAiToRegister() {
        let transition = RegistrationAttempt.idle.on(.started)
        XCTAssertEqual(transition.attempt, .waitingFor(.register))
        XCTAssertEqual(transition.command, .register)
    }

    func testReturningWithoutRegistrationAwaitsConfirmationThenFails() {
        let waiting = RegistrationAttempt.waitingFor(.register).on(.leftApp).attempt.on(.returned).attempt
        XCTAssertTrue(waiting.awaitsConfirmation)
        XCTAssertEqual(waiting.on(.graceExpired).attempt, .failed(.notConfirmed))
    }

    func testBusySdkDelaysTheVerdict() {
        let busy = RegistrationAttempt.waitingFor(.register).on(.leftApp).attempt.on(.returned).attempt.on(.sdkState(.registering)).attempt
        XCTAssertFalse(busy.awaitsConfirmation)
        XCTAssertEqual(busy.on(.graceExpired).attempt, busy)
    }

    func testOldRegistrationIsRemovedOnceAndRegisteredAgain() {
        let unregister = RegistrationAttempt.waitingFor(.register).on(.sdkError(.alreadyRegistered))
        XCTAssertEqual(unregister.command, .unregister)
        let again = unregister.attempt.on(.sdkError(.alreadyUnregistered))
        XCTAssertEqual(again.command, .register)
        XCTAssertEqual(again.attempt.on(.sdkError(.alreadyRegistered)).attempt, .failed(.sdkError))
    }

    func testRegisteredEndsEvenAFailedAttempt() {
        XCTAssertEqual(RegistrationAttempt.failed(.timeout).on(.sdkState(.registered)).attempt, .idle)
    }
}
