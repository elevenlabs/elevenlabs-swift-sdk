@testable import ElevenLabs
import XCTest

final class ElevenLabsTests: XCTestCase {
    func testVersionExists() {
        // Simple test to verify the module loads and version is accessible
        XCTAssertEqual(ElevenLabs.version, "2.0.0")
    }

    func testConfigurationDefault() {
        // Test that default configuration can be created
        let config = ElevenLabs.Configuration.default
        XCTAssertNil(config.apiEndpoint)
        XCTAssertEqual(config.logLevel, .warning)
        XCTAssertFalse(config.debugMode)
    }

    func testConversationConfigInit() {
        // Test that ConversationConfig can be initialized
        let config = ConversationConfig()
        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertNil(config.conversationOverrides)
    }
}
