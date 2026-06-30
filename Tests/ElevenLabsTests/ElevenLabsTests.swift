@testable import ElevenLabs
import XCTest

final class ElevenLabsTests: XCTestCase {
    func testDefaultEndpoints() {
        let endpoints = ElevenLabsEndpoints.production
        XCTAssertEqual(endpoints.voiceWebSocket.absoluteString, "wss://livekit.rtc.elevenlabs.io")
        XCTAssertEqual(endpoints.textWebSocket.absoluteString, "wss://api.elevenlabs.io/v1/convai/conversation")
        XCTAssertEqual(endpoints.apiBase.absoluteString, "https://api.elevenlabs.io")
    }

    func testConversationConfigInit() {
        let config = ConversationConfig()
        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertFalse(config.textOnly)
    }
}
