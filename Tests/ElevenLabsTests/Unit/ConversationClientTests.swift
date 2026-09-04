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
        XCTAssertTrue(client.chatHistory.isEmpty)
        XCTAssertFalse(client.isMicMuted)
    }

    func testConversationTokenReportsUnknownAgentId() async throws {
        _ = try await client.startVoiceConversation(.conversationToken("tok"))
        assertConnected(agentId: "unknown")
    }

    func testStartConversationMirrorsSessionStateThroughActiveAndEnd() async throws {
        let result = try await client.startVoiceConversation(.publicAgent(id: "test-agent-id"))

        assertConnected(agentId: "test-agent-id")
        XCTAssertEqual(result.callInfo.agentId, "test-agent-id")
        XCTAssertEqual(result.callInfo.conversationId, "test-conversation-id")
        XCTAssertNotNil(result.metrics.initiationMetadata)
        XCTAssertFalse(client.isMicMuted)
        XCTAssertFalse(mockWebRTCConnectionManager.isMicrophoneMuted)

        let payload: [String: Any] = [
            "type": "agent_response",
            "agent_response_event": [
                "agent_response": "Hello from the agent",
                "event_id": 1,
                "response_id": "response-1"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        await mockWebRTCConnectionManager.receive(data: data)
        await waitForPublished(client.$chatHistory) {
            $0.last?.message?.content == "Hello from the agent"
        }

        XCTAssertEqual(client.chatHistory.last?.message?.content, "Hello from the agent")

        await client.endConversation()
        XCTAssertEqual(client.state, .ended(reason: .userEnded))
    }

    func testRestartEndsPreviousSessionAndStartsFresh() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        assertConnected(agentId: "first-agent")
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 0)

        await client.endConversation()
        XCTAssertEqual(client.state, .ended(reason: .userEnded))
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)

        _ = try await client.startVoiceConversation(.publicAgent(id: "second-agent"))

        assertConnected(agentId: "second-agent")
        XCTAssertTrue(client.chatHistory.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)
    }

    func testStartWhileActiveEndsPreviousAndStartsNext() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        assertConnected(agentId: "first-agent")

        _ = try await client.startVoiceConversation(.publicAgent(id: "second-agent"))

        assertConnected(agentId: "second-agent")
        XCTAssertTrue(client.chatHistory.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)
    }

    func testLatestOverlappingStartWins() async throws {
        mockWebRTCConnectionManager.autoSucceedAgentReady = false

        let firstStart = Task {
            try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        }
        await mockWebRTCConnectionManager.waitUntilWaitingForAgent()

        _ = try await client.startTextOnlyConversation(.publicAgent(id: "second-agent"))

        await XCTAssertThrowsErrorAsync {
            _ = try await firstStart.value
        }

        assertConnected(agentId: "second-agent")
    }

    func testLatestOverlappingStartOnSameTransportWins() async throws {
        mockWebRTCConnectionManager.autoSucceedAgentReady = false

        let firstStart = Task {
            try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        }
        await mockWebRTCConnectionManager.waitUntilWaitingForAgent()
        mockWebRTCConnectionManager.autoSucceedAgentReady = true

        _ = try await client.startVoiceConversation(.publicAgent(id: "second-agent"))

        await XCTAssertThrowsErrorAsync {
            _ = try await firstStart.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
        assertConnected(agentId: "second-agent")
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 2)
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)
    }

    func testResetEndsSessionAndClearsMirroredState() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))

        let payload: [String: Any] = [
            "type": "agent_response",
            "agent_response_event": [
                "agent_response": "Hello",
                "event_id": 1,
                "response_id": "response-1"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        await mockWebRTCConnectionManager.receive(data: data)
        await waitForPublished(client.$chatHistory) {
            $0.last?.message?.content == "Hello"
        }

        await client.reset()

        XCTAssertEqual(client.state, .idle)
        XCTAssertTrue(client.chatHistory.isEmpty)
        XCTAssertTrue(client.pendingToolCalls.isEmpty)
        XCTAssertNil(client.conversationMetadata)
        XCTAssertFalse(client.isMicMuted)

        // Client is reusable after reset.
        _ = try await client.startVoiceConversation(.publicAgent(id: "after-reset"))
        assertConnected(agentId: "after-reset")
    }

    func testVoiceThenTextOnlyUsesFreshSessionPerTransport() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "voice-agent"))
        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)

        _ = try await client.startTextOnlyConversation(.publicAgent(id: "text-agent"))

        assertConnected(agentId: "text-agent")
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
    }

    func testStartFailureAfterBindMirrorsErrorAndCommandsRemainUnavailable() async throws {
        mockWebRTCConnectionManager.tokenError = .authenticationFailed("Mock authentication failed")

        await XCTAssertThrowsErrorAsync {
            _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))
        } errorHandler: { error in
            let startupError = error as? ConversationStartupError
            XCTAssertEqual(startupError?.stage, .resolvingToken)
            XCTAssertEqual(startupError?.underlyingError, .authenticationFailed("Mock authentication failed"))
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
        _ = try await client.startVoiceConversation(.publicAgent(id: "recovered-agent"))
        assertConnected(agentId: "recovered-agent")
    }

    func testCancelledStartDoesNotReplaceLiveSession() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "live-agent"))

        let cancelledStart = Task { @MainActor in
            try await client.startTextOnlyConversation(.publicAgent(id: "cancelled-agent"))
        }
        cancelledStart.cancel()

        await XCTAssertThrowsErrorAsync {
            _ = try await cancelledStart.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
        assertConnected(agentId: "live-agent")
        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 0)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 0)
    }

    func testCommandThrowsNotConnectedWithNoSession() async throws {
        do {
            try await client.sendMessage("hello")
            XCTFail("Expected notConnected to be thrown")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    func testCompleteSendsResultOnlyWhenExpected() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))
        await waitForPublished(client.$conversationMetadata) { $0?.conversationId == "test-conversation-id" }

        let respondingCall = ClientToolCallEvent(
            toolName: "lookup",
            toolCallId: "responding-call",
            parametersData: Data("{}".utf8),
            eventId: 1,
            expectsResponse: true
        )
        mockWebRTCConnectionManager.deliver(.clientToolCall(respondingCall))
        await waitForPublished(client.$pendingToolCalls) { $0.count == 1 }

        let scopedRespondingCall = try XCTUnwrap(client.pendingToolCalls.first)
        XCTAssertEqual(scopedRespondingCall.conversationId, "test-conversation-id")
        let payloadCount = mockWebRTCConnectionManager.publishedPayloads.count
        try await client.complete(
            scopedRespondingCall,
            with: .init(toolCallId: "wrong-id", result: "done")
        )
        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, payloadCount + 1)
        let payload = String(
            decoding: try XCTUnwrap(mockWebRTCConnectionManager.publishedPayloads.last),
            as: UTF8.self
        )
        XCTAssertTrue(payload.contains(scopedRespondingCall.toolCallId))
        XCTAssertFalse(payload.contains("wrong-id"))
        XCTAssertTrue(client.pendingToolCalls.isEmpty)

        try await client.complete(
            scopedRespondingCall,
            with: .init(toolCallId: scopedRespondingCall.toolCallId, result: "duplicate")
        )
        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, payloadCount + 1)

        let silentCall = ClientToolCallEvent(
            toolName: "track",
            toolCallId: "silent-call",
            parametersData: Data("{}".utf8),
            eventId: 2,
            expectsResponse: false
        )
        mockWebRTCConnectionManager.deliver(.clientToolCall(silentCall))
        await waitForPublished(client.$pendingToolCalls) { $0.count == 1 }

        let scopedSilentCall = try XCTUnwrap(client.pendingToolCalls.first)
        let silentPayloadCount = mockWebRTCConnectionManager.publishedPayloads.count
        try await client.complete(
            scopedSilentCall,
            with: .init(toolCallId: scopedSilentCall.toolCallId, result: "ignored")
        )
        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, silentPayloadCount)
        XCTAssertTrue(client.pendingToolCalls.isEmpty)
    }

    func testCompleteIgnoresCallFromPreviousConversation() async throws {
        mockWebRTCConnectionManager.initiationMetadataConversationId = "first-conversation"
        _ = try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        await waitForPublished(client.$conversationMetadata) { $0?.conversationId == "first-conversation" }

        let event = ClientToolCallEvent(
            toolName: "slow-tool",
            toolCallId: "slow-call",
            parametersData: Data("{}".utf8),
            eventId: 1,
            expectsResponse: true
        )
        mockWebRTCConnectionManager.deliver(.clientToolCall(event))
        await waitForPublished(client.$pendingToolCalls) { !$0.isEmpty }
        let staleCall = try XCTUnwrap(client.pendingToolCalls.first)

        mockWebRTCConnectionManager.initiationMetadataConversationId = "second-conversation"
        _ = try await client.startVoiceConversation(.publicAgent(id: "second-agent"))
        await waitForPublished(client.$conversationMetadata) { $0?.conversationId == "second-conversation" }
        let payloadCount = mockWebRTCConnectionManager.publishedPayloads.count

        try await client.complete(
            staleCall,
            with: .init(toolCallId: staleCall.toolCallId, result: "too late")
        )

        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, payloadCount)
    }

    func testSetMicMutedUpdatesStateWithNoSession() async throws {
        await client.endConversation()
        try await client.setMicMuted(true)
        XCTAssertTrue(client.isMicMuted)

        try await client.setMicMuted(false)
        XCTAssertFalse(client.isMicMuted)

        client.markToolCallCompleted("missing-id")

        XCTAssertEqual(client.state, .idle)
    }

    func testPreStartMuteIsAppliedToConversation() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false

        try await client.setMicMuted(true)
        _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))

        XCTAssertTrue(client.isMicMuted)
        XCTAssertTrue(mockWebRTCConnectionManager.isMicrophoneMuted)
    }

    // MARK: - Agent mute

    func testAgentStartsUnmuted() {
        XCTAssertFalse(client.isAgentMuted)
    }

    func testSetAgentMutedWithNoSessionIsRememberedAndAppliedOnStart() async throws {
        mockWebRTCConnectionManager.agentAudioTrack = SpyAudioTrack()

        client.setAgentMuted(true)
        XCTAssertTrue(client.isAgentMuted)

        _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))

        XCTAssertEqual(mockWebRTCConnectionManager.appliedAgentMuted, true)
    }

    func testAgentMuteCarriesAcrossSessions() async throws {
        mockWebRTCConnectionManager.agentAudioTrack = SpyAudioTrack()
        _ = try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        client.setAgentMuted(true)

        _ = try await client.startVoiceConversation(.publicAgent(id: "second-agent"))

        XCTAssertTrue(client.isAgentMuted)
        XCTAssertEqual(mockWebRTCConnectionManager.appliedAgentMuted, true)
    }

    func testResetUnmutesTheAgent() async throws {
        mockWebRTCConnectionManager.agentAudioTrack = SpyAudioTrack()
        _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))
        client.setAgentMuted(true)

        await client.reset()

        XCTAssertFalse(client.isAgentMuted)
    }

    func testSetMicMutedIsHarmlessAfterEnd() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "test-agent"))
        await client.endConversation()

        try await client.setMicMuted(true)

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
