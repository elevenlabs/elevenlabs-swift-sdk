@testable import ElevenLabs
import Foundation
import XCTest

@MainActor
final class ConversationClientTests: XCTestCase {
    private var client: ConversationClient!
    private var mockWebRTCConnectionManager: MockWebRTCConnectionManager!
    private var mockWebSocketConnectionManager: MockWebSocketConnectionManager!
    private var dependencyProvider: TestDependencyProvider!

    override func setUp() async throws {
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        mockWebSocketConnectionManager = MockWebSocketConnectionManager()
        dependencyProvider = TestDependencyProvider(
            webRTCConnectionManager: mockWebRTCConnectionManager,
            webSocketConnectionManager: mockWebSocketConnectionManager
        )
        client = ConversationClient(dependencyProvider: dependencyProvider)
    }

    override func tearDown() async throws {
        client = nil
        mockWebRTCConnectionManager = nil
        mockWebSocketConnectionManager = nil
        dependencyProvider = nil
    }

    func testInitialStateIsIdleBeforeAnyStart() {
        XCTAssertEqual(client.state, .idle)
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertTrue(client.isMuted)
    }

    func testStartConversationMirrorsSessionStateThroughActiveAndEnd() async throws {
        try await client.startConversation(auth: .publicAgent(id: "test-agent-id"))

        XCTAssertEqual(client.state, .active(.init(agentId: "test-agent-id")))

        let payload: [String: Any] = [
            "type": "agent_response",
            "agent_response_event": [
                "agent_response": "Hello from the agent",
                "event_id": 1
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        mockWebRTCConnectionManager.receive(data: data)
        await waitForPublished(client.$messages) { $0.last?.content == "Hello from the agent" }

        XCTAssertEqual(client.messages.last?.content, "Hello from the agent")

        await client.endConversation()
        XCTAssertEqual(client.state, .ended(reason: .userEnded))
    }

    func testRestartEndsPreviousSessionAndStartsFresh() async throws {
        try await client.startConversation(auth: .publicAgent(id: "first-agent"))
        XCTAssertEqual(client.state, .active(.init(agentId: "first-agent")))
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
        // prepareConversationStart resets the manager before connect.
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)

        await client.endConversation()
        XCTAssertEqual(client.state, .ended(reason: .userEnded))
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 2)

        try await client.startConversation(auth: .publicAgent(id: "second-agent"))

        XCTAssertEqual(client.state, .active(.init(agentId: "second-agent")))
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        // +1 reset-before-connect on the second start.
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 3)
    }

    func testStartWhileActiveEndsPreviousAndStartsNext() async throws {
        try await client.startConversation(auth: .publicAgent(id: "first-agent"))
        XCTAssertEqual(client.state, .active(.init(agentId: "first-agent")))

        try await client.startConversation(auth: .publicAgent(id: "second-agent"))

        XCTAssertEqual(client.state, .active(.init(agentId: "second-agent")))
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        // 1 reset (first) + 1 end of previous session + 1 reset (second).
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 3)
    }

    func testResetEndsSessionAndClearsMirroredState() async throws {
        try await client.startConversation(auth: .publicAgent(id: "test-agent"))

        let payload: [String: Any] = [
            "type": "agent_response",
            "agent_response_event": [
                "agent_response": "Hello",
                "event_id": 1
            ]
        ]
        try mockWebRTCConnectionManager.receive(data: JSONSerialization.data(withJSONObject: payload))
        await waitForPublished(client.$messages) { $0.last?.content == "Hello" }

        await client.reset()

        XCTAssertEqual(client.state, .idle)
        XCTAssertEqual(client.startupState, .idle)
        XCTAssertNil(client.startupMetrics)
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertTrue(client.pendingToolCalls.isEmpty)
        XCTAssertNil(client.conversationMetadata)
        XCTAssertTrue(client.isMuted)

        // Client is reusable after reset.
        try await client.startConversation(auth: .publicAgent(id: "after-reset"))
        XCTAssertEqual(client.state, .active(.init(agentId: "after-reset")))
    }

    func testVoiceThenTextOnlyUsesFreshSessionPerTransport() async throws {
        try await client.startConversation(auth: .publicAgent(id: "voice-agent"))
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)

        var textConfig = ConversationConfig()
        textConfig.conversationOverrides = ConversationOverrides(textOnly: true)
        try await client.startConversation(auth: .publicAgent(id: "text-agent"), config: textConfig)

        XCTAssertEqual(client.state, .active(.init(agentId: "text-agent")))
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
    }

    func testStartFailureAfterBindLeavesClientIdleAndCommandsUnavailable() async throws {
        mockWebRTCConnectionManager.tokenError = .authenticationFailed("Mock authentication failed")

        await XCTAssertThrowsErrorAsync {
            try await client.startConversation(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .authenticationFailed("Mock authentication failed"))
        }

        XCTAssertEqual(client.state, .idle)
        guard case .failed(.token, _) = client.startupState else {
            return XCTFail("Expected mirrored startup failure after bind")
        }

        await XCTAssertThrowsErrorAsync {
            try await client.sendMessage("hello")
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .notConnected)
        }

        // A later start should still work on the same client.
        mockWebRTCConnectionManager.tokenError = nil
        try await client.startConversation(auth: .publicAgent(id: "recovered-agent"))
        XCTAssertEqual(client.state, .active(.init(agentId: "recovered-agent")))
    }

    func testCommandThrowsNotConnectedWithNoSession() async throws {
        do {
            try await client.sendMessage("hello")
            XCTFail("Expected notConnected to be thrown")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    func testNoOpMethodsAreHarmlessWithNoSession() async throws {
        await client.endConversation()
        try await client.setMuted(true)
        try await client.toggleMute()
        client.markToolCallCompleted("missing-id")

        XCTAssertEqual(client.state, .idle)
    }
}
