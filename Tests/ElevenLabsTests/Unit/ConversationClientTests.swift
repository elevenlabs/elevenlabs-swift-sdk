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
        XCTAssertTrue(client.isMicMuted)
    }

    func testStartConversationMirrorsSessionStateThroughActiveAndEnd() async throws {
        let result = try await client.startConversation(auth: .publicAgent(id: "test-agent-id"))

        assertConnected(agentId: "test-agent-id")
        XCTAssertEqual(result.callInfo.agentId, "test-agent-id")
        XCTAssertEqual(result.callInfo.conversationId, "test-conversation-id")
        XCTAssertNotNil(result.metrics.initiationMetadata)

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
        _ = try await client.startConversation(auth: .publicAgent(id: "first-agent"))
        assertConnected(agentId: "first-agent")
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 0)

        await client.endConversation()
        XCTAssertEqual(client.state, .ended(reason: .userEnded))
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)

        _ = try await client.startConversation(auth: .publicAgent(id: "second-agent"))

        assertConnected(agentId: "second-agent")
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)
    }

    func testStartWhileActiveEndsPreviousAndStartsNext() async throws {
        _ = try await client.startConversation(auth: .publicAgent(id: "first-agent"))
        assertConnected(agentId: "first-agent")

        _ = try await client.startConversation(auth: .publicAgent(id: "second-agent"))

        assertConnected(agentId: "second-agent")
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)
    }

    func testResetEndsSessionAndClearsMirroredState() async throws {
        _ = try await client.startConversation(auth: .publicAgent(id: "test-agent"))

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
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertTrue(client.pendingToolCalls.isEmpty)
        XCTAssertNil(client.conversationMetadata)
        XCTAssertTrue(client.isMicMuted)

        // Client is reusable after reset.
        _ = try await client.startConversation(auth: .publicAgent(id: "after-reset"))
        assertConnected(agentId: "after-reset")
    }

    func testVoiceThenTextOnlyUsesFreshSessionPerTransport() async throws {
        _ = try await client.startConversation(auth: .publicAgent(id: "voice-agent"))
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)

        var textConfig = ConversationConfig()
        textConfig.conversationOverrides = ConversationOverrides(textOnly: true)
        _ = try await client.startConversation(auth: .publicAgent(id: "text-agent"), config: textConfig)

        assertConnected(agentId: "text-agent")
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
    }

    func testStartFailureAfterBindMirrorsErrorAndCommandsRemainUnavailable() async throws {
        mockWebRTCConnectionManager.tokenError = .authenticationFailed("Mock authentication failed")

        await XCTAssertThrowsErrorAsync {
            _ = try await client.startConversation(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .authenticationFailed("Mock authentication failed"))
        }

        guard case let .error(error) = client.state else {
            return XCTFail("Expected mirrored startup error after bind")
        }
        XCTAssertEqual(error, .authenticationFailed("Mock authentication failed"))

        await XCTAssertThrowsErrorAsync {
            try await client.sendMessage("hello")
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .notConnected)
        }

        // A later start should still work on the same client.
        mockWebRTCConnectionManager.tokenError = nil
        _ = try await client.startConversation(auth: .publicAgent(id: "recovered-agent"))
        assertConnected(agentId: "recovered-agent")
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
        try await client.setMicMuted(true)
        try await client.toggleMicMute()
        client.markToolCallCompleted("missing-id")

        XCTAssertEqual(client.state, .idle)
    }

    func testMicMethodsAreHarmlessAfterEnd() async throws {
        _ = try await client.startConversation(auth: .publicAgent(id: "test-agent"))
        await client.endConversation()

        try await client.setMicMuted(false)
        try await client.toggleMicMute()

        XCTAssertTrue(client.isMicMuted)
        XCTAssertEqual(client.state, .ended(reason: .userEnded))
    }

    private func assertConnected(
        agentId: String,
        conversationId: String = "test-conversation-id",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .connected(info) = client.state else {
            return XCTFail("Expected connected state, got \(client.state)", file: file, line: line)
        }
        XCTAssertEqual(info.agentId, agentId, file: file, line: line)
        XCTAssertEqual(info.conversationId, conversationId, file: file, line: line)
    }
}
