@testable import ElevenLabs
import XCTest

final class ElevenLabsTests: XCTestCase {
    func testConversationConfigInit() {
        let config = ConversationConfig()
        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertEqual(config.endpoints, .production)
    }
}
