@testable import ElevenLabs
import XCTest

final class ElevenLabsSDKTests: XCTestCase {
    func testSDKVersionExists() {
        XCTAssertEqual(ElevenLabs.version, "3.2.2")
        XCTAssertFalse(ElevenLabs.version.isEmpty)
    }

    func testDefaultConfiguration() {
        let config = ElevenLabs.Configuration.default

        XCTAssertEqual(config.logLevel, .warning)
        XCTAssertFalse(config.debugMode)
    }

    func testCustomConfiguration() {
        let config = ElevenLabs.Configuration(
            logLevel: .debug,
            debugMode: true
        )

        XCTAssertEqual(config.logLevel, .debug)
        XCTAssertTrue(config.debugMode)
    }

    @MainActor
    func testConfigureSDK() {
        let config = ElevenLabs.Configuration(
            logLevel: .info,
            debugMode: false
        )

        ElevenLabs.configure(config)
    }

    @MainActor
    func testStartConversationWithAgentId() async {
        let config = ConversationConfig()
        let client = ConversationClient()

        do {
            _ = try await client.startConversation(agentId: "test-agent-123", config: config)
            // In a proper test environment with mocks, we'd verify connection
        } catch {
            // Expected to fail without proper API setup
            XCTAssertTrue(error is ConversationError)
        }
    }

    func testConversationTokenAuthConfiguration() {
        let auth = ConversationCredentials.conversationToken("test-token-123")
        switch auth.authSource {
        case let .conversationToken(token):
            XCTAssertEqual(token, "test-token-123")
        default:
            XCTFail("Expected conversationToken case")
        }
    }

    func testSignedWebSocketURLAuthConfiguration() throws {
        let url = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-123&conversation_signature=sig"
        let auth = try ConversationCredentials.signedWebSocketURL(url)

        switch auth.authSource {
        case let .signedWebSocketURL(signedURL, agentId):
            XCTAssertEqual(signedURL, url)
            XCTAssertEqual(agentId, "agent-123")
            XCTAssertEqual(auth.agentId, "agent-123")
        default:
            XCTFail("Expected signedWebSocketURL case")
        }
    }

    func testCustomTokenProviderAuthConfiguration() {
        let tokenProvider: @Sendable () async throws -> String = {
            "dynamic-token-123"
        }
        let auth = ConversationCredentials.customTokenProvider(tokenProvider)
        switch auth.authSource {
        case .customTokenProvider:
            break // Success - provider is configured
        default:
            XCTFail("Expected customTokenProvider case")
        }
    }

    func testConfigurationLogLevels() {
        let debugConfig = ElevenLabs.Configuration(logLevel: .debug)
        let infoConfig = ElevenLabs.Configuration(logLevel: .info)
        let warningConfig = ElevenLabs.Configuration(logLevel: .warning)
        let errorConfig = ElevenLabs.Configuration(logLevel: .error)

        XCTAssertEqual(debugConfig.logLevel, .debug)
        XCTAssertEqual(infoConfig.logLevel, .info)
        XCTAssertEqual(warningConfig.logLevel, .warning)
        XCTAssertEqual(errorConfig.logLevel, .error)
    }

    func testEndpointsDefaultToProduction() {
        XCTAssertEqual(ConversationConfig().endpoints, .production)
        XCTAssertEqual(Endpoints(), .production)
    }

    func testEndpointsOverrideIndividualHosts() throws {
        let endpoints = try Endpoints(voiceWebSocket: XCTUnwrap(URL(string: "wss://rtc.example.com")))
        XCTAssertEqual(endpoints.voiceWebSocket.absoluteString, "wss://rtc.example.com")
        XCTAssertEqual(endpoints.textWebSocket, Endpoints.production.textWebSocket)
        XCTAssertEqual(endpoints.conversationToken, Endpoints.production.conversationToken)
    }

    func testConversationConfigDefaults() {
        let config = ConversationConfig()

        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertFalse(config.conversationOverrides.textOnly)
        XCTAssertEqual(config.endpoints, .production)
    }

    func testAuthenticationMethods() {
        let agentAuth = ConversationCredentials.publicAgent(id: "agent-123")
        let tokenAuth = ConversationCredentials.conversationToken("token-456")
        let providerAuth = ConversationCredentials.customTokenProvider {
            "provided-token"
        }

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

        switch providerAuth.authSource {
        case .customTokenProvider:
            break // Success
        default:
            XCTFail("Expected customTokenProvider case")
        }
    }

    func testSDKModuleImports() {
        // Verify that all necessary types are accessible
        XCTAssertNotNil(ElevenLabs.self)
        XCTAssertNotNil(ConversationClient.self)
        XCTAssertNotNil(ConversationConfig.self)
        XCTAssertNotNil(ConversationError.self)
        XCTAssertNotNil(ConversationState.self)
        XCTAssertNotNil(Language.self)
    }
}
