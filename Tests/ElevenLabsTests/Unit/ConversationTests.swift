import Combine

// swiftlint:disable file_length type_body_length
@testable import ElevenLabs
import Foundation
import LiveKit
import XCTest

@MainActor
final class ConversationTests: XCTestCase {
    private var conversation: Conversation!
    private var mockWebRTCConnectionManager: MockWebRTCConnectionManager!
    private var mockWebSocketConnectionManager: MockWebSocketConnectionManager!
    private var dependencyProvider: TestDependencyProvider!
    private let capturedErrors = ValueRecorder<ConversationError>()

    override func setUp() async throws {
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        mockWebRTCConnectionManager.connectionError = ConversationError.connectionFailed("Mock connection failed")
        mockWebSocketConnectionManager = MockWebSocketConnectionManager()
        dependencyProvider = TestDependencyProvider(
            webRTCConnectionManager: mockWebRTCConnectionManager,
            webSocketConnectionManager: mockWebSocketConnectionManager
        )
        conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: makeCallbacks())
        await capturedErrors.reset()
    }

    override func tearDown() async throws {
        conversation = nil
        mockWebRTCConnectionManager = nil
        mockWebSocketConnectionManager = nil
        dependencyProvider = nil
        await capturedErrors.reset()
    }

    @MainActor
    func testConversationInitialState() {
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertTrue(conversation.isMuted)
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testStartConversationSuccessUpdatesStartupState() async throws {
        let stateExpectation = expectation(description: "startup becomes active")

        let config = makeConfig()
        let callbacks = makeCallbacks(onStartupStateChange: { state in
            if case .active = state {
                stateExpectation.fulfill()
            }
        })
        let conversation = Conversation(dependencyProvider: dependencyProvider, config: config, callbacks: callbacks)

        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
            config: config
        )

        await fulfillment(of: [stateExpectation], timeout: 1.0)

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
        XCTAssertFalse(mockWebRTCConnectionManager.publishedPayloads.isEmpty)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent-id")))
        guard case let .active(callInfo, metrics) = conversation.startupState else {
            return XCTFail("Expected active startup state")
        }
        XCTAssertEqual(callInfo.agentId, "test-agent-id")
        XCTAssertEqual(metrics.conversationInitAttempts, 1)
        XCTAssertEqual(conversation.startupMetrics?.total, metrics.total)
        let errorsAfterSuccess = await capturedErrors.values()
        XCTAssertTrue(errorsAfterSuccess.isEmpty)
    }

    func testStartConversationConfiguresIncomingEventHandler() async throws {
        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
            config: makeConfig()
        )

        XCTAssertNotNil(mockWebRTCConnectionManager.onEventReceived)

        let payload: [String: Any] = [
            "type": "user_transcript",
            "user_transcription_event": [
                "user_transcript": "Hello from raw data",
                "event_id": 99
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        mockWebRTCConnectionManager.receive(data: data)
        await waitForPublished(conversation.$messages) { $0.last?.content == "Hello from raw data" }

        XCTAssertEqual(conversation.messages.last?.content, "Hello from raw data")
        XCTAssertEqual(conversation.messages.last?.role, .user)
    }

    func testStartConversationHandlesIncomingDataBeforeAgentReady() async throws {
        // Hold agent-ready so we can deliver protocol data while still connecting.
        mockWebRTCConnectionManager.autoSucceedAgentReady = false

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
                config: makeConfig()
            )
        }

        await waitForEventHandlerInstalled(on: mockWebRTCConnectionManager)

        guard mockWebRTCConnectionManager.onEventReceived != nil else {
            mockWebRTCConnectionManager.succeedAgentReady()
            try await startTask.value
            return XCTFail("Expected incoming event handler to be installed before agent ready")
        }

        let payload: [String: Any] = [
            "type": "conversation_initiation_metadata",
            "conversation_initiation_metadata_event": [
                "conversation_id": "conversation-before-ready",
                "agent_output_audio_format": "pcm_16000",
                "user_input_audio_format": "pcm_16000"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        mockWebRTCConnectionManager.receive(data: data)
        await waitForPublished(conversation.$conversationMetadata) { $0?.conversationId == "conversation-before-ready" }

        XCTAssertEqual(conversation.conversationMetadata?.conversationId, "conversation-before-ready")

        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value
    }

    func testStaleProtocolDataHandlerDoesNotMutateEndedConversation() async throws {
        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
            config: makeConfig()
        )

        let staleHandler = try XCTUnwrap(mockWebRTCConnectionManager.onEventReceived)

        await conversation.endConversation()

        staleHandler(.agentResponse(AgentResponseEvent(response: "This should be ignored", eventId: 101)))
        // Drain the MainActor so the handler's spawned Task has run (and been rejected).
        await Task { @MainActor in }.value

        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testStartConversationConfiguresRoomObservationHandlers() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false

        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
            config: makeConfig()
        )

        XCTAssertNotNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertFalse(conversation.isMuted)

        mockWebRTCConnectionManager.onRemoteSpeakingChanged?(true)
        await waitForPublished(conversation.$agentState) { $0 == .speaking }

        XCTAssertEqual(conversation.agentState, .speaking)
    }

    func testStartTextOnlyPublicAgentUsesWebSocketConnectionManager() async throws {
        let config = makeConfig(configure: { config in
            config.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
            config: config
        )

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 0)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.scheme, "wss")
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.host, "api.elevenlabs.io")
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.queryItems.count, 1)
        XCTAssertEqual(
            mockWebSocketConnectionManager.lastConnectedURL?.queryItems["agent_id"],
            "test-agent-id"
        )
        XCTAssertFalse(mockWebSocketConnectionManager.sentPayloads.isEmpty)
        XCTAssertEqual(try sentEventType(from: mockWebSocketConnectionManager.sentPayloads[0]), "conversation_initiation_client_data")
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent-id")))

        let payload: [String: Any] = [
            "type": "agent_response",
            "agent_response_event": [
                "agent_response": "Hello over WebSocket",
                "event_id": 101
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        mockWebSocketConnectionManager.receive(data: data)
        await waitForPublished(conversation.$messages) { $0.last?.content == "Hello over WebSocket" }

        XCTAssertEqual(conversation.messages.last?.content, "Hello over WebSocket")
        XCTAssertEqual(conversation.messages.last?.role, .agent)
    }

    func testStartAfterEndedThrowsAlreadyActive() async throws {
        try await conversation.startConversation(auth: .publicAgent(id: "test-agent-id"), config: makeConfig())
        await conversation.endConversation()
        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))

        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(auth: .publicAgent(id: "test-agent-id"), config: makeConfig())
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .alreadyActive)
        }
    }

    func testStartTextOnlySignedURLUsesProvidedWebSocketURL() async throws {
        let signedURL = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-private&conversation_signature=sig"
        let config = makeConfig(configure: { config in
            config.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        try await conversation.startConversation(
            auth: .signedWebSocketURL(signedURL),
            config: config
        )

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 0)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.absoluteString, signedURL)
        XCTAssertFalse(mockWebSocketConnectionManager.sentPayloads.isEmpty)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "agent-private")))
    }

    func testSignedWebSocketURLRejectsURLWithoutAgentId() {
        let urlMissingAgent = "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=sig"
        XCTAssertThrowsError(try ConversationCredentials.signedWebSocketURL(urlMissingAgent)) { error in
            guard let convError = error as? ConversationError,
                  case .authenticationFailed = convError
            else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }

    func testStartTextOnlyRejectsConversationTokenAuth() async throws {
        let config = makeConfig(configure: { config in
            config.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        do {
            try await conversation.startConversation(
                auth: .conversationToken("livekit-token"),
                config: config
            )
            XCTFail("Expected text-only startup to reject LiveKit token auth")
        } catch let error as ConversationError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }

    @MainActor
    func testSendMessage() async {
        // Test sending message when not connected
        do {
            try await conversation.sendMessage("Hello")
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    @MainActor
    func testToggleMuteWhenNotConnected() async {
        do {
            try await conversation.toggleMute()
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    @MainActor
    func testSetMutedWhenNotConnected() async {
        do {
            try await conversation.setMuted(true)
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    @MainActor
    func testSetMicrophoneMutedUsesConnectionManagerAudioControl() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false

        try await conversation.startConversation(auth: .publicAgent(id: "test-agent"), config: makeConfig())

        try await conversation.setMicrophoneMuted(true)

        XCTAssertTrue(mockWebRTCConnectionManager.isMicrophoneMuted)
        XCTAssertTrue(conversation.isMuted)
    }

    @MainActor
    func testInterruptAgentWhenNotConnected() async {
        do {
            try await conversation.interruptAgent()
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    @MainActor
    func testUpdateContextWhenNotConnected() async {
        do {
            try await conversation.updateContext("test context")
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    @MainActor
    func testSendFeedbackWhenNotConnected() async {
        do {
            try await conversation.sendFeedback(FeedbackEvent.Score.like, eventId: 123)
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testStartConversationTokenFailure() async {
        mockWebRTCConnectionManager.tokenError = .authenticationFailed("Mock authentication failed")

        let config = makeConfig()

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: config
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .authenticationFailed("Mock authentication failed"))
        }

        guard case let .failed(.token(conversationError), metrics) = conversation.startupState else {
            return XCTFail("Expected startup failure due to token")
        }

        XCTAssertEqual(conversationError, .authenticationFailed("Mock authentication failed"))
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(conversation.startupMetrics?.tokenFetch, metrics.tokenFetch)
        let errorsAfterTokenFailure = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterTokenFailure, [.authenticationFailed("Mock authentication failed")])
    }

    func testStartConversationConnectionFailure() async {
        mockWebRTCConnectionManager.shouldFailConnection = true

        let config = makeConfig()

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: config
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Mock connection failed"))
        }

        guard case let .failed(.room(conversationError), metrics) = conversation.startupState else {
            return XCTFail("Expected startup failure due to room connect")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Mock connection failed"))
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(conversation.startupMetrics?.roomConnect, metrics.roomConnect)
        let errorsAfterConnectionFailure = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterConnectionFailure, [.connectionFailed("Mock connection failed")])
    }

    func testStartConversationAgentTimeoutFailure() async {
        mockWebRTCConnectionManager.autoSucceedAgentReady = false

        let startupConfig = ConversationStartupConfiguration(agentReadyTimeout: 0.05)
        let config = makeConfig(startupConfiguration: startupConfig)

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: config
            )
        }

        await waitForEventHandlerInstalled(on: mockWebRTCConnectionManager)
        try? await conversation.setMuted(false)
        XCTAssertFalse(conversation.isMuted)
        mockWebRTCConnectionManager.timeoutAgentReady()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .agentTimeout)
        }

        guard case .failed(.agentTimeout, _) = conversation.startupState else {
            return XCTFail("Expected agent timeout failure state")
        }
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertTrue(conversation.isMuted)
        XCTAssertNil(mockWebRTCConnectionManager.room)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertNil(mockWebRTCConnectionManager.errorHandler)
        let errorsAfterAgentTimeout = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterAgentTimeout, [.agentTimeout])
    }

    func testStartConversationConversationInitFailure() async {
        mockWebRTCConnectionManager.publishError = ConversationError.connectionFailed("Publish failed")

        let config = makeConfig()

        guard let conversation else { return }

        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: config
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Publish failed"))
        }

        guard case let .failed(.conversationInit(conversationError), _) = conversation.startupState else {
            return XCTFail("Expected conversation init failure state")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Publish failed"))
        XCTAssertNil(mockWebRTCConnectionManager.room)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertNil(mockWebRTCConnectionManager.errorHandler)
        let errorsAfterInitFailure = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterInitFailure, [.connectionFailed("Publish failed")])
    }

    func testAgentResponseCallbackTogglesFeedbackAvailability() async throws {
        let gotResponse = expectation(description: "agent response")
        // Feedback flips more than once (start→false, response→true, feedback→false).
        let feedbackStates = ValueRecorder<Bool>()

        let callbacks = makeCallbacks(configure: { callbacks in
            callbacks.onAgentResponse = { text, eventId in
                XCTAssertEqual(text, "Hello")
                XCTAssertEqual(eventId, 42)
                gotResponse.fulfill()
            }
            callbacks.onCanSendFeedbackChange = { canSend in
                Task { await feedbackStates.append(canSend) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: callbacks)

        try await conversation.startConversation(auth: .publicAgent(id: "test"), config: makeConfig())

        mockWebRTCConnectionManager.deliver(.agentResponse(AgentResponseEvent(response: "Hello", eventId: 42)))

        await fulfillment(of: [gotResponse], timeout: 1.0)
        let initialFeedbackState = await waitForLastValue(feedbackStates) { $0 == true }
        XCTAssertEqual(initialFeedbackState, true)

        try await conversation.sendFeedback(FeedbackEvent.Score.like, eventId: 42)

        let updatedFeedbackState = await waitForLastValue(feedbackStates) { $0 == false }
        XCTAssertEqual(updatedFeedbackState, false)
    }

    func testVadScoreCallbackReceivesScores() async throws {
        let gotVad = expectation(description: "vad score")
        let callbacks = makeCallbacks(configure: { callbacks in
            callbacks.onVadScore = { score in
                XCTAssertEqual(score, 0.87)
                gotVad.fulfill()
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: callbacks)
        try await conversation.startConversation(auth: .publicAgent(id: "test"), config: makeConfig())

        mockWebRTCConnectionManager.deliver(.vadScore(VadScoreEvent(vadScore: 0.87)))

        await fulfillment(of: [gotVad], timeout: 1.0)
    }

    func testAgentToolResponseCallbackReceivesEvent() async throws {
        let gotTool = expectation(description: "agent tool response")
        let callbacks = makeCallbacks(configure: { callbacks in
            callbacks.onAgentToolResponse = { event in
                XCTAssertEqual(event.toolName, "lookup_weather")
                gotTool.fulfill()
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: callbacks)
        try await conversation.startConversation(auth: .publicAgent(id: "test"), config: makeConfig())

        mockWebRTCConnectionManager.deliver(.agentToolResponse(AgentToolResponseEvent(
            toolName: "lookup_weather", toolCallId: "id", toolType: "action", isError: false, eventId: 10
        )))

        await fulfillment(of: [gotTool], timeout: 1.0)
    }

    func testInterruptionCallbackDisablesFeedback() async throws {
        let gotInterruption = expectation(description: "interruption")
        let feedbackStates = ValueRecorder<Bool>()

        let callbacks = makeCallbacks(configure: { callbacks in
            callbacks.onInterruption = { id in
                XCTAssertEqual(id, 7)
                gotInterruption.fulfill()
            }
            callbacks.onCanSendFeedbackChange = { canSend in
                Task { await feedbackStates.append(canSend) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: callbacks)
        try await conversation.startConversation(auth: .publicAgent(id: "test"), config: makeConfig())

        mockWebRTCConnectionManager.deliver(.interruption(InterruptionEvent(eventId: 7)))

        await fulfillment(of: [gotInterruption], timeout: 1.0)
        let interruptionFeedbackState = await waitForLastValue(feedbackStates) { $0 == false }
        XCTAssertEqual(interruptionFeedbackState, false)
    }

    @MainActor
    func testSendToolResultWhenNotConnected() async {
        do {
            try await conversation.sendToolResult(for: "tool-id", result: "result", isError: false)
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    @MainActor
    func testEndConversationWhenNotActive() async {
        // Should not throw error when ending inactive conversation
        await conversation.endConversation()
        XCTAssertEqual(conversation.state, .idle)
    }

    func testConversationErrorEquality() {
        XCTAssertEqual(ConversationError.notConnected, ConversationError.notConnected)
        XCTAssertEqual(ConversationError.alreadyActive, ConversationError.alreadyActive)
        XCTAssertEqual(ConversationError.authenticationFailed("test"), ConversationError.authenticationFailed("test"))
        XCTAssertEqual(ConversationError.connectionFailed("test"), ConversationError.connectionFailed("test"))
        XCTAssertEqual(ConversationError.agentTimeout, ConversationError.agentTimeout)
        XCTAssertEqual(ConversationError.microphoneToggleFailed("test"), ConversationError.microphoneToggleFailed("test"))

        XCTAssertNotEqual(ConversationError.notConnected, ConversationError.alreadyActive)
    }

    func testConversationStateEnum() {
        let idleState: ConversationState = .idle
        let connectingState: ConversationState = .connecting
        let activeState: ConversationState = .active(CallInfo(agentId: "test"))

        XCTAssertNotEqual(idleState, connectingState)
        XCTAssertNotEqual(connectingState, activeState)
        XCTAssertNotEqual(idleState, activeState)
    }

    func testFeedbackTypeEnum() {
        XCTAssertEqual(FeedbackEvent.Score.like.rawValue, "like")
        XCTAssertEqual(FeedbackEvent.Score.dislike.rawValue, "dislike")
        XCTAssertNotEqual(FeedbackEvent.Score.like, FeedbackEvent.Score.dislike)
    }

    func testAgentDisconnectEndsConversation() async throws {
        let gotDisconnect = expectation(description: "agent disconnect")
        let config = makeConfig()
        let callbacks = makeCallbacks(configure: { callbacks in
            callbacks.onDisconnect = { reason in
                XCTAssertEqual(reason, .agent)
                gotDisconnect.fulfill()
            }
        })
        let conversation = Conversation(dependencyProvider: dependencyProvider, config: config, callbacks: callbacks)

        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id"),
            config: config
        )
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent-id")))
        let disconnectsBefore = mockWebRTCConnectionManager.disconnectCallCount

        await mockWebRTCConnectionManager.onDisconnected?()

        XCTAssertEqual(
            mockWebRTCConnectionManager.disconnectCallCount,
            disconnectsBefore + 1,
            "Agent disconnect should trigger webRTCConnectionManager.disconnect()"
        )
        await fulfillment(of: [gotDisconnect], timeout: 1.0)
        XCTAssertEqual(conversation.state, .ended(reason: .remoteDisconnected))
    }
}

// swiftlint:enable file_length type_body_length

extension ConversationTests {
    private func makeConfig(
        startupConfiguration: ConversationStartupConfiguration = .default,
        configure: ((inout ConversationConfig) -> Void)? = nil
    ) -> ConversationConfig {
        var config = ConversationConfig(startupConfiguration: startupConfiguration)
        configure?(&config)
        return config
    }

    private func makeCallbacks(
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        configure: ((inout ConversationCallbacks) -> Void)? = nil
    ) -> ConversationCallbacks {
        var callbacks = ConversationCallbacks(onStartupStateChange: onStartupStateChange)

        callbacks.onError = { [capturedErrors] error in
            Task { await capturedErrors.append(error) }
        }

        configure?(&callbacks)
        return callbacks
    }
}

extension URL {
    fileprivate var queryItems: [String: String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value
            } ?? [:]
    }
}

private func sentEventType(from data: Data) throws -> String? {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["type"] as? String
}
