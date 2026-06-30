@testable import ElevenLabs
import XCTest

final class ElevenLabsSDKTests: XCTestCase {
    func testSDKVersionExists() {
        XCTAssertEqual(SDKVersion.version, "3.2.0")
        XCTAssertFalse(SDKVersion.version.isEmpty)
    }

    func testDefaultEndpoints() {
        let endpoints = ElevenLabsEndpoints.production

        XCTAssertEqual(endpoints.voiceWebSocket.absoluteString, "wss://livekit.rtc.elevenlabs.io")
        XCTAssertEqual(endpoints.textWebSocket.absoluteString, "wss://api.elevenlabs.io/v1/convai/conversation")
        XCTAssertEqual(endpoints.apiBase.absoluteString, "https://api.elevenlabs.io")
    }

    func testCustomEndpointsOverrideSingleField() {
        let endpoints = ElevenLabsEndpoints(
            voiceWebSocket: URL(string: "wss://livekit.custom.example.com")!
        )

        // Overridden field is applied; the rest fall back to production.
        XCTAssertEqual(endpoints.voiceWebSocket.absoluteString, "wss://livekit.custom.example.com")
        XCTAssertEqual(endpoints.apiBase, ElevenLabsEndpoints.production.apiBase)
    }

    func testApiBaseConvenienceDerivesEndpoints() {
        let endpoints = ElevenLabsEndpoints.apiBase(URL(string: "https://my-proxy.example.com")!)

        XCTAssertEqual(endpoints.apiBase.absoluteString, "https://my-proxy.example.com")
        // Scheme is upgraded to wss for the text endpoint.
        XCTAssertEqual(endpoints.textWebSocket.absoluteString, "wss://my-proxy.example.com/v1/convai/conversation")
        // LiveKit stays on the production host unless overridden.
        XCTAssertEqual(endpoints.voiceWebSocket, ElevenLabsEndpoints.production.voiceWebSocket)
    }

    func testLogLevelDefaultsToWarningAndIsConfigurable() {
        XCTAssertEqual(ConversationConfig().logLevel, .warning)

        let config = ConversationConfig(logLevel: .trace)
        XCTAssertEqual(config.logLevel, .trace)
    }

    @MainActor
    func testStartConversationWithAgentId() async {
        let client = ConversationClient()

        do {
            try await client.start(auth: .publicAgent(id: "test-agent-123"), config: ConversationConfig())
            // In a proper test environment with mocks, we'd verify connection
            XCTAssertEqual(client.state, .connected)
        } catch {
            // Expected to fail without proper API setup
            XCTAssertTrue(error is ConversationError)
        }
    }

    func testConversationTokenAuthConfiguration() {
        let auth = ConversationAuth.conversationToken("test-token-123")
        switch auth.authSource {
        case let .conversationToken(token):
            XCTAssertEqual(token, "test-token-123")
        default:
            XCTFail("Expected conversationToken case")
        }
    }

    func testSignedWebSocketURLAuthConfiguration() throws {
        let url = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-123&conversation_signature=sig"
        let auth = try ConversationAuth.signedWebSocketURL(url)

        switch auth.authSource {
        case let .signedWebSocketURL(signedURL, agentId):
            XCTAssertEqual(signedURL, url)
            XCTAssertEqual(agentId, "agent-123")
        default:
            XCTFail("Expected signedWebSocketURL case")
        }
    }

    

    func testLogLevelOrdering() {
        XCTAssertLessThan(LogLevel.error, .warning)
        XCTAssertLessThan(LogLevel.warning, .info)
        XCTAssertLessThan(LogLevel.info, .debug)
        XCTAssertLessThan(LogLevel.debug, .trace)
    }

    func testConversationConfigDefaults() {
        let config = ConversationConfig()

        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertFalse(config.textOnly)
    }

    func testAuthenticationMethods() {
        let agentAuth = ConversationAuth.publicAgent(id: "agent-123")
        let tokenAuth = ConversationAuth.conversationToken("token-456")

        switch agentAuth.authSource {
        case let .publicAgentId(id):
            XCTAssertEqual(id, "agent-123")
        default:
            XCTFail("Expected publicAgentId case")
        }

        switch tokenAuth.authSource {
        case let .conversationToken(token):
            XCTAssertEqual(token, "token-456")
        default:
            XCTFail("Expected conversationToken case")
        }
    }

    func testSDKModuleImports() {
        // Verify that all necessary types are accessible
        XCTAssertNotNil(ConversationClient.self)
        XCTAssertNotNil(Conversation.self)
        XCTAssertNotNil(ConversationConfig.self)
        XCTAssertNotNil(ConversationError.self)
        XCTAssertNotNil(ConversationState.self)
        XCTAssertNotNil(Language.self)
    }
}
