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
    private var mockTokenService: MockTokenService!
    private var dependencyProvider: TestDependencyProvider!
    private let capturedErrors = ValueRecorder<ConversationError>()

    override func setUp() async throws {
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        mockWebRTCConnectionManager.connectionError = ConversationError.connectionFailed("Mock connection failed")
        mockWebSocketConnectionManager = MockWebSocketConnectionManager()
        mockTokenService = MockTokenService()
        dependencyProvider = TestDependencyProvider(
            tokenService: mockTokenService,
            webRTCConnectionManager: mockWebRTCConnectionManager,
            webSocketConnectionManager: mockWebSocketConnectionManager
        )
        conversation = Conversation(dependencyProvider: dependencyProvider)
        await capturedErrors.reset()
    }

    override func tearDown() async throws {
        conversation = nil
        mockWebRTCConnectionManager = nil
        mockWebSocketConnectionManager = nil
        mockTokenService = nil
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

        let options = makeConfig(
            onStartupStateChange: { state in
                if case .active = state {
                    stateExpectation.fulfill()
                }
            }
        )

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: options
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()

        await fulfillment(of: [stateExpectation], timeout: 1.0)
        try await startTask.value

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
        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: makeConfig()
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

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
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(conversation.messages.last?.content, "Hello from raw data")
        XCTAssertEqual(conversation.messages.last?.role, .user)
    }

    func testStartConversationHandlesIncomingDataBeforeAgentReady() async throws {
        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: makeConfig()
            )
        }

        await Task.yield()
        for _ in 0 ..< 10 where mockWebRTCConnectionManager.onEventReceived == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

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
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(conversation.conversationMetadata?.conversationId, "conversation-before-ready")

        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value
    }

    func testStaleProtocolDataHandlerDoesNotMutateEndedConversation() async throws {
        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: makeConfig()
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

        let staleHandler = try XCTUnwrap(mockWebRTCConnectionManager.onEventReceived)

        await conversation.endConversation()

        staleHandler(.agentResponse(AgentResponseEvent(response: "This should be ignored", eventId: 101)))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testStartConversationConfiguresRoomObservationHandlers() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: makeConfig()
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

        XCTAssertNotNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertFalse(conversation.isMuted)

        mockWebRTCConnectionManager.onRemoteSpeakingChanged?(true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(conversation.agentState, .speaking)
    }

    func testStartTextOnlyPublicAgentUsesWebSocketConnectionManager() async throws {
        let options = makeConfig(configure: { options in
            options.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        try await conversation.startConversation(
            auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
            options: options
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
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(conversation.messages.last?.content, "Hello over WebSocket")
        XCTAssertEqual(conversation.messages.last?.role, .agent)
    }

    func testTextOnlyStartDisconnectsPreviousActiveManagerBeforeSwitchingTransports() async throws {
        mockWebRTCConnectionManager.room = Room()
        mockWebRTCConnectionManager.onEventReceived = { _ in }
        mockWebRTCConnectionManager.onDisconnected = {}
        mockWebRTCConnectionManager.onRemoteSpeakingChanged = { _ in }
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.ended(reason: .userEnded))

        let options = makeConfig(configure: { options in
            options.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        try await conversation.startConversation(
            auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
            options: options
        )

        XCTAssertEqual(mockWebRTCConnectionManager.disconnectCallCount, 1)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
        XCTAssertNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent-id")))
    }

    func testStartTextOnlySignedURLUsesProvidedWebSocketURL() async throws {
        let signedURL = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-private&conversation_signature=sig"
        let options = makeConfig(configure: { options in
            options.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        try await conversation.startConversation(
            auth: .signedWebSocketURL(signedURL),
            options: options
        )

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 0)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.absoluteString, signedURL)
        XCTAssertFalse(mockWebSocketConnectionManager.sentPayloads.isEmpty)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "agent-private")))
    }

    func testSignedWebSocketURLRejectsURLWithoutAgentId() {
        let urlMissingAgent = "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=sig"
        XCTAssertThrowsError(try ElevenLabsConfiguration.signedWebSocketURL(urlMissingAgent)) { error in
            guard let convError = error as? ConversationError,
                  case .authenticationFailed = convError
            else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }

    func testStartTextOnlyRejectsConversationTokenAuth() async throws {
        let options = makeConfig(configure: { options in
            options.conversationOverrides = ConversationOverrides(textOnly: true)
        })

        do {
            try await conversation.startConversation(
                auth: .conversationToken("livekit-token"),
                options: options
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
        mockWebRTCConnectionManager.room = Room()
        mockWebRTCConnectionManager.isMicrophoneMuted = false
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.active(.init(agentId: "test-agent")))

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

        let options = makeConfig()

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options
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
        let errorsAfterTokenFailure = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterTokenFailure, [.authenticationFailed("Mock authentication failed")])
    }

    func testStartConversationConnectionFailure() async {
        mockWebRTCConnectionManager.shouldFailConnection = true

        let options = makeConfig()

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options
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
        let errorsAfterConnectionFailure = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterConnectionFailure, [.connectionFailed("Mock connection failed")])
    }

    func testStartConversationAgentTimeoutFailure() async {
        let options = ConversationStartupConfiguration(agentReadyTimeout: 0.05)

        let conversationConfig = makeConfig(startupConfiguration: options)

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: conversationConfig
            )
        }

        await Task.yield()
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
        let errorsAfterAgentTimeout = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterAgentTimeout, [.agentTimeout])
    }

    func testStartConversationConversationInitFailure() async {
        mockWebRTCConnectionManager.publishError = ConversationError.connectionFailed("Publish failed")

        let options = makeConfig()

        guard let conversation else { return }

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options
            )
        }

        // Wait for agent ready, THEN publish will fail
        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
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
        let errorsAfterInitFailure = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterInitFailure, [.connectionFailed("Publish failed")])
    }

    func testAgentResponseCallbackTogglesFeedbackAvailability() async throws {
        let receivedResponses = ValueRecorder<(String, Int)>()
        let feedbackStates = ValueRecorder<Bool>()

        let options = makeConfig(configure: { options in
            options.onAgentResponse = { text, eventId in
                Task { await receivedResponses.append((text, eventId)) }
            }
            options.onCanSendFeedbackChange = { canSend in
                Task { await feedbackStates.append(canSend) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)

        // Set up mock connection manager with a room and active state so sendFeedback can publish
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(ConversationState.active(.init(agentId: "test")))

        await conversation._testing_handleIncomingEvent(
            IncomingEvent.agentResponse(AgentResponseEvent(response: "Hello", eventId: 42))
        )

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let responsesSnapshot = await receivedResponses.values()
        XCTAssertEqual(responsesSnapshot.count, 1)
        XCTAssertEqual(responsesSnapshot.first?.0, "Hello")
        XCTAssertEqual(responsesSnapshot.first?.1, 42)
        let initialFeedbackState = await feedbackStates.last()
        XCTAssertEqual(initialFeedbackState, true)

        try await conversation.sendFeedback(FeedbackEvent.Score.like, eventId: 42)

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let updatedFeedbackState = await feedbackStates.last()
        XCTAssertEqual(updatedFeedbackState, false)
    }

    func testVadScoreCallbackReceivesScores() async {
        let vadScores = ValueRecorder<Double>()
        let options = makeConfig(configure: { options in
            options.onVadScore = { score in
                Task { await vadScores.append(score) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)
        await conversation._testing_handleIncomingEvent(IncomingEvent.vadScore(VadScoreEvent(vadScore: 0.87)))

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let vadSnapshot = await vadScores.values()
        XCTAssertEqual(vadSnapshot, [0.87])
    }

    func testAgentToolResponseCallbackReceivesEvent() async {
        let capturedToolNames = ValueRecorder<String>()
        let options = makeConfig(configure: { options in
            options.onAgentToolResponse = { (event: AgentToolResponseEvent) in
                Task { await capturedToolNames.append(event.toolName) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)
        let toolEvent = AgentToolResponseEvent(toolName: "end_call", toolCallId: "id", toolType: "action", isError: false, eventId: 10)

        await conversation._testing_handleIncomingEvent(IncomingEvent.agentToolResponse(toolEvent))

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let toolNames = await capturedToolNames.values()
        XCTAssertEqual(toolNames, ["end_call"])
    }

    func testInterruptionCallbackDisablesFeedback() async {
        let interruptionIds = ValueRecorder<Int>()
        let feedbackStates = ValueRecorder<Bool>()

        let options = makeConfig(configure: { options in
            options.onInterruption = { id in
                Task { await interruptionIds.append(id) }
            }
            options.onCanSendFeedbackChange = { canSend in
                Task { await feedbackStates.append(canSend) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)
        await conversation._testing_handleIncomingEvent(IncomingEvent.interruption(InterruptionEvent(eventId: 7)))

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let interruptionSnapshot = await interruptionIds.values()
        XCTAssertEqual(interruptionSnapshot, [7])
        let interruptionFeedbackState = await feedbackStates.last()
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
        let disconnectReasons = ValueRecorder<DisconnectionReason>()
        let options = makeConfig(configure: { options in
            options.onDisconnect = { reason in
                Task { await disconnectReasons.append(reason) }
            }
        })

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: options
            )
        }
        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent-id")))
        // capture call counts before the disconnect event.
        let disconnectsBefore = mockWebRTCConnectionManager.disconnectCallCount
        // Simulate agent disconnect
        await mockWebRTCConnectionManager.onDisconnected?()
        // assert disconnect was handled with correct reasons
        XCTAssertEqual(
            mockWebRTCConnectionManager.disconnectCallCount,
            disconnectsBefore + 1,
            "Agent disconnect should trigger webRTCConnectionManager.disconnect()"
        )
        let reasons = await disconnectReasons.values(waitingFor: 1)
        XCTAssertEqual(reasons, [.agent])
        XCTAssertEqual(conversation.state, .ended(reason: .remoteDisconnected))
    }
}

// swiftlint:enable file_length type_body_length

@MainActor
extension XCTestCase {
    fileprivate func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> some Sendable,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail(message(), file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}

actor ValueRecorder<Value> {
    private var storage: [Value] = []

    func append(_ value: Value) {
        storage.append(value)
    }

    func reset() {
        storage.removeAll()
    }

    func values() -> [Value] {
        storage
    }

    func values(waitingFor expectedCount: Int, timeout: TimeInterval = 1.0) async -> [Value] {
        guard expectedCount > 0 else {
            return storage
        }

        let deadline = Date().addingTimeInterval(timeout)

        while storage.count < expectedCount, Date() < deadline {
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            let sleepInterval = remaining > 0 ? min(remaining, 0.01) : 0
            if sleepInterval <= 0 {
                break
            }
            let nanos = UInt64(sleepInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: max(nanos, 1_000_000)) // minimum 1ms
        }

        return storage
    }

    func last() -> Value? {
        storage.last
    }
}

extension ConversationTests {
    private func makeConfig(
        startupConfiguration: ConversationStartupConfiguration = .default,
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        configure: ((inout ConversationOptions) -> Void)? = nil
    ) -> ConversationOptions {
        var options = ConversationOptions(
            onStartupStateChange: onStartupStateChange,
            startupConfiguration: startupConfiguration
        )

        options.onError = { [capturedErrors] error in
            Task { await capturedErrors.append(error) }
        }

        configure?(&options)
        return options
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
