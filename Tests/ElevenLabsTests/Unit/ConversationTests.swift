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
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: makeConfig(),
            callbacks: makeCallbacks()
        )
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
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testStartConversationSuccessReturnsResult() async throws {
        let config = makeConfig()
        let conversation = Conversation(dependencyProvider: dependencyProvider, config: config, callbacks: makeCallbacks())

        let result = try await conversation.start(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id")
        )

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
        XCTAssertFalse(mockWebRTCConnectionManager.publishedPayloads.isEmpty)
        guard case let .connected(callInfo) = conversation.state else {
            return XCTFail("Expected connected state")
        }
        XCTAssertEqual(callInfo.agentId, "test-agent-id")
        XCTAssertEqual(callInfo.conversationId, "test-conversation-id")
        XCTAssertEqual(result.callInfo, callInfo)
        XCTAssertEqual(result.metrics.agentReady, 0)
        XCTAssertNotNil(result.metrics.initiationMetadata)
        let errorsAfterSuccess = await capturedErrors.values()
        XCTAssertTrue(errorsAfterSuccess.isEmpty)
    }

    func testConversationCanOnlyStartOnce() async throws {
        _ = try await conversation.start(auth: .publicAgent(id: "first-agent"))
        await conversation.endConversation()

        await XCTAssertThrowsErrorAsync {
            _ = try await conversation.start(auth: .publicAgent(id: "second-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .alreadyStarted)
        }

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 1)
    }

    func testStartConversationConfiguresIncomingEventHandler() async throws {
        _ = try await conversation.start(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id")
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
        mockWebRTCConnectionManager.autoDeliverInitiationMetadata = false

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            _ = try await conversation.start(
                auth: ConversationCredentials.publicAgent(id: "test-agent-id")
            )
        }

        await mockWebRTCConnectionManager.waitForEventHandlerInstalled()

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

        guard case let .connected(callInfo) = conversation.state else {
            return XCTFail("Expected connected state")
        }
        XCTAssertEqual(callInfo.conversationId, "conversation-before-ready")
    }

    func testStaleProtocolDataHandlerDoesNotMutateEndedConversation() async throws {
        _ = try await conversation.start(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id")
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

        _ = try await conversation.start(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id")
        )

        XCTAssertNotNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)

        mockWebRTCConnectionManager.onRemoteSpeakingChanged?(true)
        await waitForPublished(conversation.$agentState) { $0 == .speaking }

        XCTAssertEqual(conversation.agentState, .speaking)
    }

    func testStartTextOnlyPublicAgentUsesWebSocketConnectionManager() async throws {
        let startupStages = ValueRecorder<ConversationStartupState>()
        let config = makeConfig(configure: { config in
            config.conversationOverrides = ConversationOverrides(textOnly: true)
        })
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: makeCallbacks()
        )
        var cancellable: AnyCancellable?
        cancellable = conversation.$state.sink { state in
            if case let .connecting(stage) = state {
                Task { await startupStages.append(stage) }
            }
        }

        _ = try await conversation.start(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id")
        )
        cancellable?.cancel()

        let reportedStartupStages = await waitForValues(startupStages, count: 3)
        XCTAssertEqual(
            reportedStartupStages,
            [.preparing, .sendingConversationInit, .waitingForInitiationMetadata(timeout: 5.0)]
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
        XCTAssertTrue(conversation.state.isConnected)

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

    func testStartTextOnlySignedURLUsesProvidedWebSocketURL() async throws {
        let signedURL = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent-private&conversation_signature=sig"
        let config = makeConfig(configure: { config in
            config.conversationOverrides = ConversationOverrides(textOnly: true)
        })
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: makeCallbacks()
        )

        _ = try await conversation.start(auth: .signedWebSocketURL(signedURL))

        XCTAssertEqual(mockWebRTCConnectionManager.connectCallCount, 0)
        XCTAssertEqual(mockWebSocketConnectionManager.connectCallCount, 1)
        XCTAssertEqual(mockWebSocketConnectionManager.lastConnectedURL?.absoluteString, signedURL)
        XCTAssertFalse(mockWebSocketConnectionManager.sentPayloads.isEmpty)
        guard case let .connected(info) = conversation.state else {
            return XCTFail("Expected connected state")
        }
        XCTAssertEqual(info.agentId, "agent-private")
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
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: makeCallbacks()
        )

        do {
            _ = try await conversation.start(auth: .conversationToken("livekit-token"))
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
    func testSetMicMutedWhileIdleAppliesOnStart() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false

        try await conversation.setMicMuted(true)
        _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))

        XCTAssertTrue(mockWebRTCConnectionManager.isMicrophoneMuted)
    }

    @MainActor
    func testSetHardwareMicMutedUsesConnectionManagerAudioControl() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false

        _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))

        try await conversation.setHardwareMicMuted(true)

        XCTAssertTrue(mockWebRTCConnectionManager.isMicrophoneMuted)
    }

    @MainActor
    func testSetMicMutedUsesSoftwareMuteWhenConfigured() async throws {
        mockWebRTCConnectionManager.isMicrophoneMuted = false
        let config = makeConfig(configure: { config in
            config.audioConfiguration = AudioPipelineConfiguration(microphoneMuteMode: .software())
        })
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: makeCallbacks()
        )

        _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))

        try await conversation.setMicMuted(true)

        XCTAssertFalse(mockWebRTCConnectionManager.isMicrophoneMuted)
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

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .authenticationFailed("Mock authentication failed"))
        }

        guard case let .error(conversationError) = conversation.state else {
            return XCTFail("Expected error state due to token failure")
        }

        XCTAssertEqual(conversationError, .authenticationFailed("Mock authentication failed"))
        let errorsAfterTokenFailure = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterTokenFailure, [.authenticationFailed("Mock authentication failed")])
    }

    func testStartConversationConnectionFailure() async {
        mockWebRTCConnectionManager.shouldFailConnection = true

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Mock connection failed"))
        }

        guard case let .error(conversationError) = conversation.state else {
            return XCTFail("Expected error state due to room connect failure")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Mock connection failed"))
        mockWebRTCConnectionManager.deliverStartupState(.waitingForAgent(timeout: 1))
        XCTAssertEqual(conversation.state, .error(conversationError))

        let errorsAfterConnectionFailure = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterConnectionFailure, [.connectionFailed("Mock connection failed")])
    }

    func testStartConversationAgentTimeoutFailure() async {
        mockWebRTCConnectionManager.autoSucceedAgentReady = false
        mockWebRTCConnectionManager.timeoutAgentReady()

        let startupConfig = ConversationStartupConfiguration(agentReadyTimeout: 0.05)
        let config = makeConfig(startupConfiguration: startupConfig)
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: makeCallbacks()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .agentTimeout)
        }

        guard case .error(.agentTimeout) = conversation.state else {
            return XCTFail("Expected agent timeout error state")
        }
        XCTAssertNil(mockWebRTCConnectionManager.room)
        XCTAssertNil(mockWebRTCConnectionManager.onDisconnected)
        XCTAssertNil(mockWebRTCConnectionManager.onEventReceived)
        XCTAssertNil(mockWebRTCConnectionManager.onRemoteSpeakingChanged)
        XCTAssertNil(mockWebRTCConnectionManager.errorHandler)
        let errorsAfterAgentTimeout = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterAgentTimeout, [.agentTimeout])
    }

    func testCancelledStartupEndsConversation() async {
        mockWebRTCConnectionManager.autoDeliverInitiationMetadata = false
        let startTask = Task {
            try await conversation.start(auth: .publicAgent(id: "test-agent"))
        }

        await waitForPublished(conversation.$state) {
            $0 == .connecting(.waitingForInitiationMetadata(timeout: 5))
        }
        startTask.cancel()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
    }

    func testEndDuringStartupRemainsEnded() async {
        mockWebRTCConnectionManager.autoDeliverInitiationMetadata = false
        let startTask = Task {
            try await conversation.start(auth: .publicAgent(id: "test-agent"))
        }

        await waitForPublished(conversation.$state) {
            $0 == .connecting(.waitingForInitiationMetadata(timeout: 5))
        }
        await conversation.endConversation()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
    }

    func testEndDuringWaitingForAgentDoesNotReportFailure() async {
        mockWebRTCConnectionManager.autoSucceedAgentReady = false
        let startTask = Task {
            try await conversation.start(auth: .publicAgent(id: "test-agent"))
        }

        await waitForPublished(conversation.$state) {
            if case .connecting(.waitingForAgent) = $0 { return true }
            return false
        }
        await conversation.endConversation()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
        // onError appends asynchronously; give it a beat, then confirm End didn't fake a timeout.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let errors = await capturedErrors.values()
        XCTAssertTrue(errors.isEmpty)
    }

    func testStartConversationInitiationMetadataTimeout() async {
        mockWebRTCConnectionManager.autoDeliverInitiationMetadata = false

        let startupConfig = ConversationStartupConfiguration(initiationMetadataTimeout: 0.01)
        let config = makeConfig(startupConfiguration: startupConfig)
        conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: makeCallbacks()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .initiationMetadataTimeout)
        }

        guard case .error(.initiationMetadataTimeout) = conversation.state else {
            return XCTFail("Expected initiation metadata timeout error state")
        }
        let errorsAfterTimeout = await waitForValues(capturedErrors, count: 1)
        XCTAssertEqual(errorsAfterTimeout, [.initiationMetadataTimeout])
    }

    func testStartConversationConversationInitFailure() async {
        mockWebRTCConnectionManager.publishError = ConversationError.connectionFailed("Publish failed")

        guard let conversation else { return }

        await XCTAssertThrowsErrorAsync {
            _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Publish failed"))
        }

        guard case let .error(conversationError) = conversation.state else {
            return XCTFail("Expected conversation init error state")
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

    func testSendFeedbackWhileConnected() async throws {
        let conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: makeConfig()
        )

        _ = try await conversation.start(auth: .publicAgent(id: "test"))

        try await conversation.sendFeedback(FeedbackEvent.Score.like, eventId: 42)

        let payload = try XCTUnwrap(mockWebRTCConnectionManager.publishedPayloads.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "feedback")
        XCTAssertEqual(json["score"] as? String, "like")
        XCTAssertEqual(json["event_id"] as? Int, 42)
    }

    func testVadScoreCallbackReceivesScores() async throws {
        let gotVad = expectation(description: "vad score")
        let callbacks = makeCallbacks(configure: { callbacks in
            callbacks.onVadScore = { score in
                XCTAssertEqual(score, 0.87)
                gotVad.fulfill()
            }
        })

        let conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: makeConfig(),
            callbacks: callbacks
        )
        _ = try await conversation.start(auth: .publicAgent(id: "test"))

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

        let conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: makeConfig(),
            callbacks: callbacks
        )
        _ = try await conversation.start(auth: .publicAgent(id: "test"))

        mockWebRTCConnectionManager.deliver(.agentToolResponse(AgentToolResponseEvent(
            toolName: "lookup_weather", toolCallId: "id", toolType: "action", isError: false, eventId: 10
        )))

        await fulfillment(of: [gotTool], timeout: 1.0)
    }

    @MainActor
    func testSendToolResultWhenNotConnected() async {
        do {
            try await conversation.sendToolResult(
                .init(toolCallId: "tool-id", result: "result")
            )
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testToolCallLifecycle() async throws {
        _ = try await conversation.start(auth: .publicAgent(id: "test"))

        let toolCall = try ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_123",
            parametersData: JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1,
            expectsResponse: false
        )
        mockWebRTCConnectionManager.deliver(.clientToolCall(toolCall))
        await waitForPublished(conversation.$pendingToolCalls) { $0.contains { $0.toolCallId == "call_123" } }

        XCTAssertEqual(conversation.pendingToolCalls.count, 1)
        XCTAssertEqual(conversation.pendingToolCalls.first?.toolCallId, "call_123")

        let payloadCountBeforeResult = mockWebRTCConnectionManager.publishedPayloads.count
        try await conversation.sendToolResult(.init(toolCallId: "call_123", result: "success"))

        XCTAssertTrue(conversation.pendingToolCalls.isEmpty)
        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, payloadCountBeforeResult + 1)
        let lastPayload = mockWebRTCConnectionManager.publishedPayloads.last ?? Data()
        let lastPayloadString = String(data: lastPayload, encoding: .utf8) ?? ""
        XCTAssertTrue(lastPayloadString.contains("call_123"))
        XCTAssertTrue(lastPayloadString.contains("success"))
    }

    func testSendToolResultEncodesEncodableResult() async throws {
        struct Weather: Encodable {
            let temperature: Int
            let condition: String
        }

        _ = try await conversation.start(auth: .publicAgent(id: "test"))

        try await conversation.sendToolResult(
            .init(
                toolCallId: "call_42",
                result: Weather(temperature: 25, condition: "Sunny")
            )
        )

        let payload = try XCTUnwrap(mockWebRTCConnectionManager.publishedPayloads.last)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "client_tool_result")
        let resultString = try XCTUnwrap(envelope["result"] as? String)
        let parsed = try JSONSerialization.jsonObject(with: XCTUnwrap(resultString.data(using: .utf8))) as? [String: Any]
        XCTAssertEqual(parsed?["temperature"] as? Int, 25)
        XCTAssertEqual(parsed?["condition"] as? String, "Sunny")
    }

    @MainActor
    func testEndIdleConversation() async {
        await conversation.endConversation()
        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
    }

    func testConversationErrorEquality() {
        XCTAssertEqual(ConversationError.notConnected, ConversationError.notConnected)
        XCTAssertEqual(ConversationError.alreadyStarted, ConversationError.alreadyStarted)
        XCTAssertEqual(ConversationError.authenticationFailed("test"), ConversationError.authenticationFailed("test"))
        XCTAssertEqual(ConversationError.connectionFailed("test"), ConversationError.connectionFailed("test"))
        XCTAssertEqual(ConversationError.agentTimeout, ConversationError.agentTimeout)
        XCTAssertEqual(ConversationError.initiationMetadataTimeout, ConversationError.initiationMetadataTimeout)
        XCTAssertEqual(ConversationError.microphoneToggleFailed("test"), ConversationError.microphoneToggleFailed("test"))

        XCTAssertNotEqual(ConversationError.notConnected, ConversationError.alreadyStarted)
    }

    func testConversationStateEnum() {
        let idleState: ConversationState = .idle
        let connectingState: ConversationState = .connecting(.preparing)
        let connectedState: ConversationState = .connected(
            CallInfo(agentId: "test", conversationId: "conversation")
        )

        XCTAssertNotEqual(idleState, connectingState)
        XCTAssertNotEqual(connectingState, connectedState)
        XCTAssertNotEqual(idleState, connectedState)
        XCTAssertTrue(connectingState.isConnecting)
        XCTAssertTrue(connectedState.isConnected)
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
                XCTAssertEqual(reason, .remoteDisconnected)
                gotDisconnect.fulfill()
            }
        })
        let conversation = Conversation(dependencyProvider: dependencyProvider, config: config, callbacks: callbacks)

        _ = try await conversation.start(
            auth: ConversationCredentials.publicAgent(id: "test-agent-id")
        )
        XCTAssertTrue(conversation.state.isConnected)
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
        configure: ((inout ConversationCallbacks) -> Void)? = nil
    ) -> ConversationCallbacks {
        var callbacks = ConversationCallbacks()

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
