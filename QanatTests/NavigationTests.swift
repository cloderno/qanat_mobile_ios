import XCTest
@testable import Qanat

final class NavigationTests: XCTestCase {
    func testConversationShowsVoiceUntilUserLeftIt() {
        XCTAssertEqual(signedInScreen(chosen: .settings, conversation: true, leftVoice: false), .voice)
        XCTAssertEqual(signedInScreen(chosen: .settings, conversation: true, leftVoice: true), .settings)
        XCTAssertEqual(signedInScreen(chosen: nil, conversation: false, leftVoice: false), .chat)
    }

    func testResetLinkFromEmail() {
        let link = ResetLink(URL(string: "https://qm.e-vko.kz/auth/reset?uid=MQ&token=abc-123")!)
        XCTAssertEqual(link?.uid, "MQ")
        XCTAssertEqual(link?.token, "abc-123")
        XCTAssertNil(ResetLink(URL(string: "https://qm.e-vko.kz/app/assistant?chat=1")!))
        XCTAssertNil(ResetLink(URL(string: "qanatmobile://?metaWearablesAction=register")!))
    }

    func testPushChatIdFromDataOrLink() {
        XCTAssertEqual(pushChatId(["chat_uuid": "c1"]), "c1")
        XCTAssertEqual(pushChatId(["link": "/app/assistant?chat=c2"]), "c2")
        XCTAssertNil(pushChatId(["link": "/app/meetings/5"]))
        XCTAssertNil(chatIdFromAssistantLink("/app/assistant?chat="))
    }
}
