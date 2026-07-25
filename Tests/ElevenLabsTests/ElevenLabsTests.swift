@testable import ElevenLabs
import XCTest

final class ElevenLabsTests: XCTestCase {
    func testConversationConfigInit() {
        let config = ConversationConfig()
        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertFalse(config.conversationOverrides.textOnly)
        XCTAssertEqual(config.endpoints, .production)
    }
}
