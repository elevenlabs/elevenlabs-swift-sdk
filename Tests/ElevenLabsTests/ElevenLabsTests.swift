@testable import ElevenLabs
import XCTest

final class ElevenLabsTests: XCTestCase {
    func testConversationConfigInit() {
        let config = ConversationConfig()
        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertNil(config.conversationOverrides.clientEvents)
        XCTAssertEqual(config.endpoints, .production)
    }
}
