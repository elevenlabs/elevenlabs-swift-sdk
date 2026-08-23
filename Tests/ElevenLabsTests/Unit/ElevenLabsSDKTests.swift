@testable import ElevenLabs
import XCTest

final class ElevenLabsSDKTests: XCTestCase {
    func testSDKVersionExists() {
        XCTAssertEqual(ElevenLabs.version, "3.2.2")
        XCTAssertFalse(ElevenLabs.version.isEmpty)
    }

    @MainActor
    func testStartConversationWithAgentId() async {
        let config = ConversationConfig()
        let client = ConversationClient()

        do {
            _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent-123"))
            // In a proper test environment with mocks, we'd verify connection
        } catch {
            // Expected to fail without proper API setup
            XCTAssertTrue(error is ConversationError)
        }
    }

    func testEndpointsDefaultToProduction() {
        XCTAssertEqual(ConversationConfig().endpoints, .production)
        XCTAssertEqual(Endpoints(), .production)
    }

    func testEndpointsOverrideIndividualHosts() throws {
        let endpoints = try Endpoints(voiceWebSocket: XCTUnwrap(URL(string: "wss://rtc.example.com")))
        XCTAssertEqual(endpoints.voiceWebSocket.absoluteString, "wss://rtc.example.com")
        XCTAssertEqual(endpoints.textWebSocket, Endpoints.production.textWebSocket)
        XCTAssertEqual(endpoints.apiBase, Endpoints.production.apiBase)
    }

    func testConversationTokenDerivesFromAPIBase() throws {
        let endpoints = try Endpoints(apiBase: XCTUnwrap(URL(string: "https://proxy.example.com/eleven")))
        XCTAssertEqual(
            endpoints.conversationToken.absoluteString,
            "https://proxy.example.com/eleven/v1/convai/conversation/token"
        )
        XCTAssertEqual(
            Endpoints.production.conversationToken.absoluteString,
            "https://api.elevenlabs.io/v1/convai/conversation/token"
        )
    }

    @MainActor
    func testWebsocketUrlKeepsEndpointQueryItems() async throws {
        let endpoints = try Endpoints(textWebSocket: XCTUnwrap(URL(string: "wss://proxy.example.com/ws?tenant=acme")))
        let resolved = try await WebSocketConnectionManager.websocketUrl(
            for: .publicAgent(id: "agent-123"),
            endpoints: endpoints
        )
        XCTAssertEqual(resolved.url.absoluteString, "wss://proxy.example.com/ws?tenant=acme&agent_id=agent-123")
        XCTAssertEqual(resolved.agentId, "agent-123")
    }

    @MainActor
    func testWebsocketUrlAppendsPublicAgentEnvironment() async throws {
        let resolved = try await WebSocketConnectionManager.websocketUrl(
            for: .publicAgent(id: "agent-123"),
            endpoints: .production,
            environment: "staging"
        )
        XCTAssertEqual(
            resolved.url.absoluteString,
            "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-123&environment=staging"
        )
    }

    func testConversationInitIncludesEnvironment() throws {
        let config = ConversationConfig(environment: "staging")
        let data = try EventSerializer.serializeOutgoingEvent(
            .conversationInit(ConversationInitEvent(config: config))
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["environment"] as? String, "staging")
    }

    func testConversationConfigDefaults() {
        let config = ConversationConfig()

        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertNil(config.conversationOverrides.clientEvents)
    }

    func testAuthenticationMethods() async throws {
        let voice = ConversationAuth.Voice.publicAgent(id: "agent-123")
        let token = ConversationAuth.Voice.conversationToken("token-456")
        let text = ConversationAuth.TextOnly.signedWebSocketURL(
            "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-123&conversation_signature=sig"
        )

        guard case let .publicAgent(id) = voice else {
            return XCTFail("Expected public voice agent")
        }
        XCTAssertEqual(id, "agent-123")
        XCTAssertEqual(token.agentId, "unknown")

        let resolved = try await WebSocketConnectionManager.websocketUrl(
            for: text,
            endpoints: .production
        )
        XCTAssertEqual(resolved.agentId, "agent-123")
    }

    func testSDKModuleImports() {
        // Verify that all necessary types are accessible
        XCTAssertNotNil(ConversationAuth.self)
        XCTAssertNotNil(ConversationClient.self)
        XCTAssertNotNil(ConversationConfig.self)
        XCTAssertNotNil(ConversationError.self)
        XCTAssertNotNil(ConversationState.self)
        XCTAssertNotNil(Language.self)
        XCTAssertNotNil(LogLevel.self)
        XCTAssertNotNil(AgentState.self)
    }
}
