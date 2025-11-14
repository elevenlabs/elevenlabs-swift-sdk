@testable import ElevenLabs
import LiveKit
import XCTest

@MainActor
final class ConversationTests: XCTestCase {
    private var conversation: Conversation!
    private var mockConnectionManager: MockConnectionManager!
    private var mockTokenService: MockTokenService!
    private var dependencyProvider: TestDependencyProvider!
    private let capturedErrors = ValueRecorder<ConversationError>()

    override func setUp() async throws {
        mockConnectionManager = MockConnectionManager()
        mockConnectionManager.connectionError = ConversationError.connectionFailed("Mock connection failed")
        mockTokenService = MockTokenService()
        dependencyProvider = TestDependencyProvider(
            tokenService: mockTokenService,
            connectionManager: mockConnectionManager,
        )
        conversation = Conversation(dependencyProvider: dependencyProvider)
        await capturedErrors.reset()
    }

    override func tearDown() async throws {
        conversation = nil
        mockConnectionManager = nil
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

        let options = makeOptions(
            onStartupStateChange: { state in
                if case .active = state {
                    stateExpectation.fulfill()
                }
            },
        )

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: options,
            )
        }

        await Task.yield()
        mockConnectionManager.succeedAgentReady()

        await fulfillment(of: [stateExpectation], timeout: 1.0)
        try await startTask.value

        XCTAssertEqual(mockConnectionManager.connectCallCount, 1)
        XCTAssertFalse(mockConnectionManager.publishedPayloads.isEmpty)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent-id")))
        guard case let .active(callInfo, metrics) = conversation.startupState else {
            return XCTFail("Expected active startup state")
        }
        XCTAssertEqual(callInfo.agentId, "test-agent-id")
        XCTAssertEqual(metrics.conversationInitAttempts, 1)
        XCTAssertFalse(metrics.agentReadyTimedOut)
        XCTAssertFalse(metrics.agentReadyViaGraceTimeout)
        XCTAssertEqual(conversation.startupMetrics?.total, metrics.total)
        let errorsAfterSuccess = await capturedErrors.values()
        XCTAssertTrue(errorsAfterSuccess.isEmpty)
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
        mockTokenService.scenario = .authenticationFailed("Mock authentication failed")

        let options = makeOptions()

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
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
        await Task.yield()
        let errorsAfterTokenFailure = await capturedErrors.values()
        XCTAssertEqual(errorsAfterTokenFailure, [.authenticationFailed("Mock authentication failed")])
    }

    func testStartConversationConnectionFailure() async {
        mockConnectionManager.shouldFailConnection = true

        let options = makeOptions()

        guard let conversation else { return }
        await XCTAssertThrowsErrorAsync {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
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
        await Task.yield()
        let errorsAfterConnectionFailure = await capturedErrors.values()
        XCTAssertEqual(errorsAfterConnectionFailure, [.connectionFailed("Mock connection failed")])
    }

    func testStartConversationAgentTimeoutFailure() async {
        let config = ConversationStartupConfiguration(
            agentReadyTimeout: 0.05,
            initRetryDelays: [0],
            failIfAgentNotReady: true,
        )

        let options = makeOptions(startupConfiguration: config)

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            )
        }

        await Task.yield()
        mockConnectionManager.timeoutAgentReady()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .agentTimeout)
        }

        guard case let .failed(.agentTimeout, metrics) = conversation.startupState else {
            return XCTFail("Expected agent timeout failure state")
        }
        XCTAssertTrue(metrics.agentReadyTimedOut)
        XCTAssertEqual(conversation.state, .idle)
        await Task.yield()
        let errorsAfterAgentTimeout = await capturedErrors.values()
        XCTAssertEqual(errorsAfterAgentTimeout, [.agentTimeout])
    }

    func testStartConversationAgentTimeoutAllowedToProceed() async throws {
        let options = makeOptions()

        let startTask = Task {
            guard let conversation = self.conversation else { return }
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            )
        }

        await Task.yield()
        // Agent succeeds via grace timeout - this is a success case, not a timeout
        mockConnectionManager.succeedAgentReady(elapsed: 0.25, viaGraceTimeout: true)

        try await startTask.value

        guard case let .active(_, metrics) = conversation.startupState else {
            return XCTFail("Expected active startup state")
        }

        // When agent succeeds via grace timeout, it's still a success (no timeout flag)
        XCTAssertFalse(metrics.agentReadyTimedOut)
        XCTAssertTrue(metrics.agentReadyViaGraceTimeout)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent")))
        let errorsAfterGraceTimeout = await capturedErrors.values()
        // No errors because agent ultimately succeeded
        XCTAssertTrue(errorsAfterGraceTimeout.isEmpty)
    }

    func testStartConversationConversationInitFailure() async {
        mockConnectionManager.publishError = ConversationError.connectionFailed("Publish failed")

        let options = makeOptions()

        guard let conversation else { return }

        let startTask = Task {
            try await conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            )
        }

        // Wait for agent ready, THEN publish will fail
        await Task.yield()
        mockConnectionManager.succeedAgentReady()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Publish failed"))
        }

        guard case let .failed(.conversationInit(conversationError), _) = conversation.startupState else {
            return XCTFail("Expected conversation init failure state")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Publish failed"))
        await Task.yield()
        let errorsAfterInitFailure = await capturedErrors.values()
        XCTAssertEqual(errorsAfterInitFailure, [.connectionFailed("Publish failed")])
    }

    func testAgentResponseCallbackTogglesFeedbackAvailability() async throws {
        let receivedResponses = ValueRecorder<(String, Int)>()
        let feedbackStates = ValueRecorder<Bool>()

        let options = makeOptions(configure: { opts in
            opts.onAgentResponse = { text, eventId in
                Task { await receivedResponses.append((text, eventId)) }
            }
            opts.onCanSendFeedbackChange = { canSend in
                Task { await feedbackStates.append(canSend) }
            }
        })

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)

        // Set up mock connection manager with a room so sendFeedback can publish
        mockConnectionManager.room = Room()

        await conversation._testing_handleIncomingEvent(
            IncomingEvent.agentResponse(AgentResponseEvent(response: "Hello", eventId: 42)),
        )

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let responsesSnapshot = await receivedResponses.values()
        XCTAssertEqual(responsesSnapshot.count, 1)
        XCTAssertEqual(responsesSnapshot.first?.0, "Hello")
        XCTAssertEqual(responsesSnapshot.first?.1, 42)
        let initialFeedbackState = await feedbackStates.last()
        XCTAssertEqual(initialFeedbackState, true)

        conversation._testing_setState(ConversationState.active(.init(agentId: "test")))
        try await conversation.sendFeedback(FeedbackEvent.Score.like, eventId: 42)

        // Allow async callbacks to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let updatedFeedbackState = await feedbackStates.last()
        XCTAssertEqual(updatedFeedbackState, false)
    }

    func testVadScoreCallbackReceivesScores() async {
        let vadScores = ValueRecorder<Double>()
        let options = makeOptions(configure: { opts in
            opts.onVadScore = { score in
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
        let options = makeOptions(configure: { opts in
            opts.onAgentToolResponse = { (event: AgentToolResponseEvent) in
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

        let options = makeOptions(configure: { opts in
            opts.onInterruption = { id in
                Task { await interruptionIds.append(id) }
            }
            opts.onCanSendFeedbackChange = { canSend in
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
}

@MainActor
extension XCTestCase {
    fileprivate func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> some Sendable,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        errorHandler: (Error) -> Void = { _ in },
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

    func last() -> Value? {
        storage.last
    }
}

extension ConversationTests {
    private func makeOptions(
        startupConfiguration: ConversationStartupConfiguration = .default,
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        configure: ((inout ConversationOptions) -> Void)? = nil,
    ) -> ConversationOptions {
        var options = ConversationOptions(
            onStartupStateChange: onStartupStateChange,
            startupConfiguration: startupConfiguration,
        )

        options.onError = { [capturedErrors] error in
            Task { await capturedErrors.append(error) }
        }

        configure?(&options)
        return options
    }
}
