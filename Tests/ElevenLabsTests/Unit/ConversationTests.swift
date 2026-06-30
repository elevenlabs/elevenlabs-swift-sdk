// swiftlint:disable file_length type_body_length
@testable import ElevenLabs
import Combine
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
        conversation = makeConversation()
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
        XCTAssertTrue(conversation.isMicMuted)
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testStartConversationSuccessUpdatesState() async throws {
        let stateExpectation = expectation(description: "state becomes connected")

        conversation = makeConversation()
        guard let conversation else { return }

        let cancellable = conversation.$state.sink { state in
            if case .connected = state {
                stateExpectation.fulfill()
            }
        }
        defer { cancellable.cancel() }

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()

        await fulfillment(of: [stateExpectation], timeout: 1.0)
        try await startTask.value

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
        XCTAssertFalse(mockWebRTCConnectionManager.publishedPayloads.isEmpty)
        XCTAssertEqual(conversation.state, .connected)
        let errorsAfterSuccess = await capturedErrors.values()
        XCTAssertTrue(errorsAfterSuccess.isEmpty)
    }

    func testStartConversationConfiguresIncomingEventHandler() async throws {
        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
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

    func testRawMessageCallbackReceivesSourceAndRawJSON() async throws {
        let rawMessages = ValueRecorder<(source: String, message: String)>()

        conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onMessage = { source, message in
                Task { await rawMessages.append((source: source, message: message)) }
            }
        }))
        guard let conversation else { return }

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
            )
        }
        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

        XCTAssertNotNil(mockWebRTCConnectionManager.onRawMessage)

        // Agent-origin frame → source "ai".
        let agentData = try JSONSerialization.data(withJSONObject: [
            "type": "agent_response",
            "agent_response_event": ["agent_response": "Hi there", "event_id": 7],
        ])
        mockWebRTCConnectionManager.receive(data: agentData)

        // User-origin frame → source "user".
        let userData = try JSONSerialization.data(withJSONObject: [
            "type": "user_transcript",
            "user_transcription_event": ["user_transcript": "Hello", "event_id": 8],
        ])
        mockWebRTCConnectionManager.receive(data: userData)

        // Recorder appends asynchronously, so don't assume arrival order.
        let received = await rawMessages.values(waitingFor: 2)
        XCTAssertEqual(received.count, 2)

        let aiMessage = received.first { $0.source == "ai" }
        XCTAssertEqual(aiMessage?.message, String(decoding: agentData, as: UTF8.self))

        let userMessage = received.first { $0.source == "user" }
        XCTAssertEqual(userMessage?.message, String(decoding: userData, as: UTF8.self))
    }

    func testStartConversationHandlesIncomingDataBeforeAgentReady() async throws {
        // Drive metadata manually so the assertion observes the injected id.
        mockWebRTCConnectionManager.autoDeliverMetadata = false
        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
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
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
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
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

        XCTAssertNotNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertFalse(conversation.isMicMuted)

        mockWebRTCConnectionManager.onRemoteSpeakingChanged?(true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(conversation.isAgentSpeaking)
    }

    func testStartTextOnlyPublicAgentUsesWebSocketConnectionManager() async throws {
        conversation = makeConversation(config: makeConfig(textOnly: true))

        try await conversation.startConversation(
            auth: .publicAgent(id: "test-agent-id")
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
        XCTAssertEqual(conversation.state, .connected)

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

    func testTextOnlyPublicAgentURLIncludesEnvironment() throws {
        let url = try WebSocketConnectionManager.url(
            for: .publicAgent(id: "test-agent-id"),
            base: ElevenLabsEndpoints.production.textWebSocket,
            environment: "staging"
        )

        XCTAssertEqual(url.queryItems["agent_id"], "test-agent-id")
        XCTAssertEqual(url.queryItems["environment"], "staging")
    }

    func testStartTextOnlySignedURLUsesProvidedWebSocketURL() async throws {
        let signedURL = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-private&conversation_signature=sig"
        conversation = makeConversation(config: makeConfig(textOnly: true))

        try await conversation.startConversation(
            auth: try .signedWebSocketURL(signedURL)
        )

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 0)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.absoluteString, signedURL)
        XCTAssertFalse(mockWebSocketConnectionManager.sentPayloads.isEmpty)
        XCTAssertEqual(conversation.state, .connected)
    }

    func testSignedWebSocketURLRejectsURLWithoutAgentId() {
        let urlMissingAgent = "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=sig"
        XCTAssertThrowsError(try ConversationAuth.signedWebSocketURL(urlMissingAgent)) { error in
            guard let convError = error as? ConversationError,
                  case .authenticationFailed = convError
            else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }

    func testStartTextOnlyRejectsConversationTokenAuth() async throws {
        conversation = makeConversation(config: makeConfig(textOnly: true))

        do {
            try await conversation.startConversation(
                auth: .conversationToken("livekit-token")
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
    func testToggleMuteWhenNotConnected() async throws {
        // Lenient when not connected: a best-effort no-op (no throw, no state
        // change), mirroring the agent-mute controls.
        let before = conversation.isMicMuted
        try await conversation.toggleMicMute()
        XCTAssertEqual(conversation.isMicMuted, before, "Mic mute must be a no-op with no live session")
    }

    @MainActor
    func testSetMutedWhenNotConnected() async throws {
        let before = conversation.isMicMuted
        try await conversation.setMicMuted(!before)
        XCTAssertEqual(conversation.isMicMuted, before, "Mic mute must be a no-op with no live session")
    }

    @MainActor
    func testSetMicrophoneMutedUsesConnectionManagerAudioControl() async throws {
        mockWebRTCConnectionManager.room = Room()
        mockWebRTCConnectionManager.isMicrophoneMuted = false
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.connected)

        try await conversation.setHardwareMicMuted(true)

        XCTAssertTrue(mockWebRTCConnectionManager.isMicrophoneMuted)
        XCTAssertTrue(conversation.isMicMuted)
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
        mockWebRTCConnectionManager.tokenError = ConversationError.authenticationFailed("Mock authentication failed")

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: self.makeConfig()
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .authenticationFailed("Mock authentication failed"))
        }

        guard case let .startupFailed(.token(conversationError)) = conversation.state else {
            return XCTFail("Expected startup failure due to token")
        }

        XCTAssertEqual(conversationError, .authenticationFailed("Mock authentication failed"))
        let errorsAfterTokenFailure = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterTokenFailure, [.authenticationFailed("Mock authentication failed")])
    }

    func testStartConversationConnectionFailure() async {
        mockWebRTCConnectionManager.shouldFailConnection = true

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: self.makeConfig()
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Mock connection failed"))
        }

        guard case let .startupFailed(.room(conversationError)) = conversation.state else {
            return XCTFail("Expected startup failure due to room connect")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Mock connection failed"))
        let errorsAfterConnectionFailure = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterConnectionFailure, [.connectionFailed("Mock connection failed")])
    }

    func testStartConversationAgentTimeoutFailure() async {
        let config = makeConfig(agentReadyTimeout: 0.05)
        conversation = makeConversation(config: config)

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent")
            )
        }

        await Task.yield()
        try? await conversation.setMicMuted(false)
        XCTAssertFalse(conversation.isMicMuted)
        mockWebRTCConnectionManager.timeoutAgentReady()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .agentTimeout)
        }

        guard case .startupFailed(.agentTimeout) = conversation.state else {
            return XCTFail("Expected agent timeout failure state")
        }
        XCTAssertTrue(conversation.isMicMuted)
        XCTAssertNil(mockWebRTCConnectionManager.room)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        let errorsAfterAgentTimeout = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterAgentTimeout, [.agentTimeout])
    }

    func testStartConversationInitializationTimeoutFailure() async {
        let config = makeConfig(agentReadyTimeout: 0.05)
        // Agent joins the room, but `conversation_initiation_metadata` never
        // arrives — the init-handshake wait must time out as `.initializationTimeout`,
        // distinct from the room-join `.agentTimeout`.
        mockWebRTCConnectionManager.autoDeliverMetadata = false
        conversation = makeConversation(config: config)

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent")
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .initializationTimeout)
        }

        guard case .startupFailed(.conversationInit(.initializationTimeout)) = conversation.state else {
            return XCTFail("Expected initialization timeout failure state")
        }
        let errorsAfterInitTimeout = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterInitTimeout, [.initializationTimeout])
    }

    func testStartConversationConversationInitFailure() async {
        mockWebRTCConnectionManager.publishError = ConversationError.connectionFailed("Publish failed")

        guard let conversation else { return }

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: self.makeConfig()
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

        guard case let .startupFailed(.conversationInit(conversationError)) = conversation.state else {
            return XCTFail("Expected conversation init failure state")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Publish failed"))
        XCTAssertNil(mockWebRTCConnectionManager.room)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        let errorsAfterInitFailure = await capturedErrors.values(waitingFor: 1)
        XCTAssertEqual(errorsAfterInitFailure, [.connectionFailed("Publish failed")])
    }

    /// Ending while the agent-join wait is in flight must win: the session ends
    /// as `.userEnded` and the spurious transport `agentTimeout` (produced when
    /// `disconnect` releases the wait) is suppressed — no `.startupFailed`, no
    /// `onError`, and the in-flight `start` unwinds as cancellation.
    func testEndDuringWaitingForAgentDoesNotReportFailure() async {
        guard let conversation else { return }

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: self.makeConfig()
            )
        }

        // Let startup progress until the manager is blocked waiting for the agent.
        for _ in 0 ..< 100 where mockWebRTCConnectionManager.lastWaitTimeout == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThan(mockWebRTCConnectionManager.lastWaitTimeout, 0)
        XCTAssertTrue(conversation.state.isConnecting)

        await conversation.endConversation()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }

        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
        // Give any (erroneous) onError dispatch a chance to land, then assert none did.
        for _ in 0 ..< 10 { await Task.yield() }
        let errors = await capturedErrors.values()
        XCTAssertTrue(errors.isEmpty, "User-initiated end must not fire onError, got \(errors)")
    }

    /// Same guarantee for the later startup phase: ending while blocked on the
    /// `conversation_initiation_metadata` handshake ends as `.userEnded` and
    /// unwinds `start` as cancellation rather than a timeout failure.
    func testEndDuringWaitingForInitDataDoesNotReportFailure() async {
        guard let conversation else { return }
        // Never deliver metadata, so startup blocks in `.waitingForInitData`.
        mockWebRTCConnectionManager.autoDeliverMetadata = false

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                config: self.makeConfig()
            )
        }

        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()

        for _ in 0 ..< 100 where conversation.state != .connecting(phase: .waitingForInitData) {
            await Task.yield()
        }
        XCTAssertEqual(conversation.state, .connecting(phase: .waitingForInitData))

        await conversation.endConversation()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }

        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
        for _ in 0 ..< 10 { await Task.yield() }
        let errors = await capturedErrors.values()
        XCTAssertTrue(errors.isEmpty, "User-initiated end must not fire onError, got \(errors)")
    }

    /// Cancelling the start task itself (rather than calling `endConversation`)
    /// while blocked on the `conversation_initiation_metadata` handshake must
    /// break the wait promptly, unwind `start` as `CancellationError` instead of
    /// a spurious init timeout, reset to `.idle`, and not fire `onError`.
    func testCancellingStartTaskDuringInitWaitUnwindsAsCancellation() async {
        guard let conversation else { return }
        // Never deliver metadata, so startup blocks in `.waitingForInitData`.
        mockWebRTCConnectionManager.autoDeliverMetadata = false

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                // Long init timeout so the cancel, not the timeout, ends the wait.
                config: self.makeConfig(agentReadyTimeout: 30.0)
            )
        }

        // Startup pre-warms a real audio engine, which needs wall-clock time, so
        // poll with short sleeps (not bare yields) until it blocks on the agent
        // gate, then release that gate so it advances to the init handshake.
        for _ in 0 ..< 200 where mockWebRTCConnectionManager.lastWaitTimeout == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        mockWebRTCConnectionManager.succeedAgentReady()

        for _ in 0 ..< 200 where conversation.state != .connecting(phase: .waitingForInitData) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(conversation.state, .connecting(phase: .waitingForInitData))

        startTask.cancel()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }

        XCTAssertEqual(conversation.state, .idle)
        for _ in 0 ..< 10 { await Task.yield() }
        let errors = await capturedErrors.values()
        XCTAssertTrue(errors.isEmpty, "Cancellation must not fire onError, got \(errors)")
    }

    func testAgentResponseCallbackAndSendFeedbackWhileConnected() async throws {
        let receivedResponses = ValueRecorder<(String, Int)>()

        let conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onAgentResponse = { text, eventId in
                Task { await receivedResponses.append((text, eventId)) }
            }
        }))

        // Set up mock connection manager with a room and active state so sendFeedback can publish
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.connected)

        await conversation._testing_handleIncomingEvent(
            IncomingEvent.agentResponse(AgentResponseEvent(response: "Hello", eventId: 42))
        )

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let responsesSnapshot = await receivedResponses.values()
        XCTAssertEqual(responsesSnapshot.count, 1)
        XCTAssertEqual(responsesSnapshot.first?.0, "Hello")
        XCTAssertEqual(responsesSnapshot.first?.1, 42)

        // Feedback for a valid agent event id while connected simply succeeds; the
        // SDK no longer tracks availability (see ConversationClient.sendFeedback).
        try await conversation.sendFeedback(FeedbackEvent.Score.like, eventId: 42)
    }

    func testVadScoreCallbackReceivesScores() async {
        let vadScores = ValueRecorder<Double>()
        let conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onVadScore = { score in
                Task { await vadScores.append(score) }
            }
        }))
        await conversation._testing_handleIncomingEvent(IncomingEvent.vadScore(VadScoreEvent(vadScore: 0.87)))

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let vadSnapshot = await vadScores.values()
        XCTAssertEqual(vadSnapshot, [0.87])
    }

    func testAgentToolResponseCallbackReceivesEvent() async {
        let capturedToolNames = ValueRecorder<String>()
        let conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onAgentToolResponse = { (event: AgentToolResponseEvent) in
                Task { await capturedToolNames.append(event.toolName) }
            }
        }))
        let toolEvent = AgentToolResponseEvent(toolName: "end_call", toolCallId: "id", toolType: "action", isError: false, eventId: 10)

        await conversation._testing_handleIncomingEvent(IncomingEvent.agentToolResponse(toolEvent))

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let toolNames = await capturedToolNames.values()
        XCTAssertEqual(toolNames, ["end_call"])
    }

    func testInterruptionCallbackReceivesEvent() async {
        let interruptionIds = ValueRecorder<Int>()

        let conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onInterruption = { id in
                Task { await interruptionIds.append(id) }
            }
        }))
        await conversation._testing_handleIncomingEvent(IncomingEvent.interruption(InterruptionEvent(eventId: 7)))

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let interruptionSnapshot = await interruptionIds.values()
        XCTAssertEqual(interruptionSnapshot, [7])
    }

    func testPingSurfacesLatencyAndRespondsWithPong() async throws {
        let pingLatencies = ValueRecorder<Int>()
        let conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onPing = { ms in
                Task { await pingLatencies.append(ms) }
            }
        }))

        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.connected)

        await conversation._testing_handleIncomingEvent(
            IncomingEvent.ping(PingEvent(eventId: 99, pingMs: 42))
        )

        // The pong is dispatched off the event-handling loop, so give the
        // detached send a chance to land.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let latencies = await pingLatencies.values()
        XCTAssertEqual(latencies, [42])

        let pong = try XCTUnwrap(
            mockWebRTCConnectionManager.publishedPayloads.compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }.first { $0["type"] as? String == "pong" },
            "Expected a pong to be published in response to the ping"
        )
        XCTAssertEqual(pong["event_id"] as? Int, 99)
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

    func testConnectionFailedPreservesUnderlyingError() {
        let urlError = URLError(.notConnectedToInternet)
        let wrapped = ConversationError.connectionFailed(urlError)

        // The original error is recoverable and downcastable to its concrete type.
        XCTAssertEqual((wrapped.underlyingError as? URLError)?.code, .notConnectedToInternet)
        // The localized description is still surfaced for display.
        XCTAssertEqual(wrapped.errorDescription, "Connection failed: \(urlError.localizedDescription)")

        // Same for the mic-toggle wrapper.
        let micWrapped = ConversationError.microphoneToggleFailed(urlError)
        XCTAssertEqual((micWrapped.underlyingError as? URLError)?.code, .notConnectedToInternet)

        // Non-wrapped cases (and string-built ones) carry no underlying error.
        XCTAssertNil(ConversationError.connectionFailed("plain").underlyingError)
        XCTAssertNil(ConversationError.notConnected.underlyingError)
    }

    func testConnectionFailedEqualityIgnoresUnderlyingError() {
        // Two wrapped errors with the same description compare equal — the boxed
        // underlying error isn't compared by identity, so equality stays driven by
        // the description string.
        let a = ConversationError.connectionFailed(URLError(.timedOut))
        let b = ConversationError.connectionFailed(URLError(.timedOut))
        XCTAssertEqual(a, b)
    }

    func testConversationStateEnum() {
        let idleState: ConversationState = .idle
        let connectingState: ConversationState = .connecting(phase: .authorizing)
        let connectedState: ConversationState = .connected

        XCTAssertNotEqual(idleState, connectingState)
        XCTAssertNotEqual(connectingState, connectedState)
        XCTAssertNotEqual(idleState, connectedState)
        XCTAssertNotEqual(
            ConversationState.connecting(phase: .authorizing),
            ConversationState.connecting(phase: .connecting)
        )
    }

    func testFeedbackTypeEnum() {
        XCTAssertEqual(FeedbackEvent.Score.like.rawValue, "like")
        XCTAssertEqual(FeedbackEvent.Score.dislike.rawValue, "dislike")
        XCTAssertNotEqual(FeedbackEvent.Score.like, FeedbackEvent.Score.dislike)
    }

    func testAgentDisconnectEndsConversation() async throws {
        let disconnectReasons = ValueRecorder<DisconnectionReason>()
        conversation = makeConversation(callbacks: makeCallbacks(configure: { callbacks in
            callbacks.onDisconnect = { reason in
                Task { await disconnectReasons.append(reason) }
            }
        }))

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent-id"),
                config: makeConfig()
            )
        }
        await Task.yield()
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value
        XCTAssertEqual(conversation.state, .connected)
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
        agentReadyTimeout: TimeInterval = 3.0,
        textOnly: Bool = false
    ) -> ConversationConfig {
        ConversationConfig(
            textOnly: textOnly,
            agentJoinTimeout: agentReadyTimeout,
            conversationInitTimeout: agentReadyTimeout
        )
    }

    private func makeCallbacks(
        configure: ((inout ConversationCallbacks) -> Void)? = nil
    ) -> ConversationCallbacks {
        var callbacks = ConversationCallbacks()
        callbacks.onError = { [capturedErrors] error in
            Task { await capturedErrors.append(error) }
        }
        configure?(&callbacks)
        return callbacks
    }

    private func makeConversation(
        config: ConversationConfig = .default,
        callbacks: ConversationCallbacks? = nil
    ) -> Conversation {
        Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: callbacks ?? makeCallbacks()
        )
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
