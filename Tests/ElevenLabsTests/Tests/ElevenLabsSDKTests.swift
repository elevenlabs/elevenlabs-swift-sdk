@testable import ElevenLabs
import XCTest

final class ElevenLabsSDKTests: XCTestCase {
    func testSDKVersionExists() {
        XCTAssertEqual(ElevenLabs.version, "2.0.11")
        XCTAssertFalse(ElevenLabs.version.isEmpty)
    }

    func testDefaultConfiguration() {
        let config = ElevenLabs.Configuration.default

        XCTAssertNil(config.apiEndpoint)
        XCTAssertEqual(config.logLevel, .warning)
        XCTAssertFalse(config.debugMode)
    }

    func testCustomConfiguration() {
        let config = ElevenLabs.Configuration(
            apiEndpoint: URL(string: "https://custom.api.com"),
            logLevel: .debug,
            debugMode: true
        )

        XCTAssertEqual(config.apiEndpoint, URL(string: "https://custom.api.com"))
        XCTAssertEqual(config.logLevel, .debug)
        XCTAssertTrue(config.debugMode)
    }

    @MainActor
    func testConfigureSDK() {
        let config = ElevenLabs.Configuration(
            apiEndpoint: URL(string: "https://test.api.com"),
            logLevel: .info,
            debugMode: false
        )

        ElevenLabs.configure(config)

        // Verify configuration was applied (in real implementation)
        // This would require exposing the internal configuration for testing
    }

    func testStartConversationWithAgentId() async {
        let config = ConversationConfig()

        do {
            let conversation = try await ElevenLabs.startConversation(
                agentId: "test-agent-123",
                config: config
            )

            XCTAssertNotNil(conversation)
            // In a proper test environment with mocks, we'd verify connection
        } catch {
            // Expected to fail without proper API setup
            XCTAssertTrue(error is ConversationError)
        }
    }

    func testStartConversationWithToken() async {
        let config = ConversationConfig()

        do {
            let conversation = try await ElevenLabs.startConversation(
                conversationToken: "test-token-123",
                config: config
            )

            XCTAssertNotNil(conversation)
        } catch {
            // Expected to fail without proper API setup
            XCTAssertTrue(error is ConversationError)
        }
    }

    func testStartConversationWithTokenProvider() async {
        let config = ConversationConfig()
        let tokenProvider: @Sendable () async throws -> String = {
            "dynamic-token-123"
        }

        do {
            let conversation = try await ElevenLabs.startConversation(
                tokenProvider: tokenProvider,
                config: config
            )

            XCTAssertNotNil(conversation)
        } catch {
            // Expected to fail without proper API setup
            XCTAssertTrue(error is ConversationError)
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

    func testConversationConfigDefaults() {
        let config = ConversationConfig()

        XCTAssertNil(config.agentOverrides)
        XCTAssertNil(config.ttsOverrides)
        XCTAssertNil(config.conversationOverrides)
    }

    func testAuthenticationMethods() {
        let agentAuth = ElevenLabsConfiguration.publicAgent(id: "agent-123")
        let tokenAuth = ElevenLabsConfiguration.conversationToken("token-456")
        let providerAuth = ElevenLabsConfiguration.customTokenProvider {
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
        XCTAssertNotNil(Conversation.self)
        XCTAssertNotNil(ConversationConfig.self)
        XCTAssertNotNil(ConversationError.self)
        XCTAssertNotNil(ConversationState.self)
        XCTAssertNotNil(Language.self)
        XCTAssertNotNil(ReceivedMessage.self)
        XCTAssertNotNil(SentMessage.self)
    }
}
