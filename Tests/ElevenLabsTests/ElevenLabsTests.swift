@testable import ElevenLabs
import XCTest

final class ElevenLabsTests: XCTestCase {
    func testConfigurationDefault() {
        let config = ElevenLabs.Configuration.default
        XCTAssertNil(config.apiEndpoint)
        XCTAssertEqual(config.logLevel, .warning)
        XCTAssertFalse(config.debugMode)
    }

    func testConversationConfigInit() {
        let config = ConversationConfig()
        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertFalse(config.conversationOverrides.textOnly)
    }
}
