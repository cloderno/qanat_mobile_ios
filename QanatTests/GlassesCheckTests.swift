import XCTest
@testable import Qanat

final class GlassesCheckTests: XCTestCase {
    private let device = GlassesDeviceInfo(name: "Ray-Ban Meta", isConnected: true, batteryLevel: 80, isWorn: true, isFolded: false)

    func testBluetoothOffComesFirst() {
        XCTAssertEqual(linkProblem(bluetoothOn: false, registered: false, device: nil, failure: .notAllowed), .bluetoothOff)
    }

    func testDeviceStateGoesBeforeLastLinkFailure() {
        var folded = device
        folded.isFolded = true
        folded.isConnected = false
        XCTAssertEqual(linkProblem(bluetoothOn: true, registered: true, device: folded, failure: .batteryLow), .folded)
        var takenOff = device
        takenOff.isWorn = false
        XCTAssertEqual(linkProblem(bluetoothOn: true, registered: true, device: takenOff, failure: .notAllowed), .takenOff)
    }

    func testLinkFailureNamesTheCauseWhenGlassesLookFine() {
        XCTAssertEqual(linkProblem(bluetoothOn: true, registered: true, device: device, failure: .glassesAppOutdated), .glassesAppUpdate)
        XCTAssertEqual(linkProblem(bluetoothOn: true, registered: true, device: device, failure: nil), .unknown)
    }

    func testMicLevelSpansSilenceToFullScale() {
        XCTAssertEqual(micLevel(0), 0)
        XCTAssertEqual(micLevel(Int(Int16.max)), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(micLevel(speechPeakAmplitude), 0)
        XCTAssertLessThan(micLevel(speechPeakAmplitude), 1)
    }

    func testButtonStageExpectsGesturesInOrder() {
        XCTAssertEqual(CheckStage.button().expectedGesture, .singlePress)
        XCTAssertEqual(CheckStage.button(done: 1).expectedGesture, .clickAndHold)
        XCTAssertNil(CheckStage.button(done: checkGestures.count).expectedGesture)
    }
}
