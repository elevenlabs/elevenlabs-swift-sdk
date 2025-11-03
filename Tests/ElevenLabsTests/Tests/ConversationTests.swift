@testable import ElevenLabs
import LiveKit
import XCTest

@MainActor
final class ConversationTests: XCTestCase {
    private var conversation: Conversation!
    private var mockConnectionManager: MockConnectionManager!
    private var mockTokenService: MockTokenService!
    private var dependencyProvider: TestDependencyProvider!
    private var capturedErrors: [ConversationError] = []

    override func setUp() async throws {
        mockConnectionManager = MockConnectionManager()
        mockConnectionManager.connectionError = ConversationError.connectionFailed("Mock connection failed")
        mockTokenService = MockTokenService()
        dependencyProvider = TestDependencyProvider(
            tokenService: mockTokenService,
            connectionManager: mockConnectionManager,
        )
        conversation = Conversation(dependencyProvider: dependencyProvider)
    }

    override func tearDown() async throws {
        conversation = nil
        mockConnectionManager = nil
        mockTokenService = nil
        dependencyProvider = nil
        capturedErrors = []
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
            try await self.conversation.startConversation(
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
        XCTAssertTrue(capturedErrors.isEmpty)
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

        await XCTAssertThrowsErrorAsync(
            try conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            ),
        ) { error in
            XCTAssertEqual(error as? ConversationError, .authenticationFailed("Mock authentication failed"))
        }

        guard case let .failed(.token(conversationError), metrics) = conversation.startupState else {
            return XCTFail("Expected startup failure due to token")
        }

        XCTAssertEqual(conversationError, .authenticationFailed("Mock authentication failed"))
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(conversation.startupMetrics?.tokenFetch, metrics.tokenFetch)
        XCTAssertEqual(capturedErrors, [.authenticationFailed("Mock authentication failed")])
    }

    func testStartConversationConnectionFailure() async {
        mockConnectionManager.shouldFailConnection = true

        let options = makeOptions()

        await XCTAssertThrowsErrorAsync(
            try conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            ),
        ) { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Mock connection failed"))
        }

        guard case let .failed(.room(conversationError), metrics) = conversation.startupState else {
            return XCTFail("Expected startup failure due to room connect")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Mock connection failed"))
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(conversation.startupMetrics?.roomConnect, metrics.roomConnect)
        XCTAssertEqual(capturedErrors, [.connectionFailed("Mock connection failed")])
    }

    func testStartConversationAgentTimeoutFailure() async {
        let config = ConversationStartupConfiguration(
            agentReadyTimeout: 0.05,
            initRetryDelays: [0],
            failIfAgentNotReady: true,
        )

        let options = makeOptions(startupConfiguration: config)

        let startTask = Task {
            try await self.conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            )
        }

        await Task.yield()
        mockConnectionManager.timeoutAgentReady()

        await XCTAssertThrowsErrorAsync(try startTask.value) { error in
            XCTAssertEqual(error as? ConversationError, .agentTimeout)
        }

        guard case let .failed(.agentTimeout, metrics) = conversation.startupState else {
            return XCTFail("Expected agent timeout failure state")
        }
        XCTAssertTrue(metrics.agentReadyTimedOut)
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(capturedErrors, [.agentTimeout])
    }

    func testStartConversationAgentTimeoutAllowedToProceed() async throws {
        let options = makeOptions()

        let startTask = Task {
            try await self.conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            )
        }

        await Task.yield()
        mockConnectionManager.timeoutAgentReady(elapsed: 0.2)

        await Task.yield()
        mockConnectionManager.succeedAgentReady(elapsed: 0.25, viaGraceTimeout: true)

        try await startTask.value

        guard case let .active(_, metrics) = conversation.startupState else {
            return XCTFail("Expected active startup state")
        }

        XCTAssertTrue(metrics.agentReadyTimedOut)
        XCTAssertTrue(metrics.agentReadyViaGraceTimeout)
        XCTAssertEqual(conversation.state, .active(.init(agentId: "test-agent")))
        XCTAssertTrue(capturedErrors.isEmpty)
    }

    func testStartConversationConversationInitFailure() async {
        mockConnectionManager.publishError = ConversationError.connectionFailed("Publish failed")

        let options = makeOptions()

        await XCTAssertThrowsErrorAsync(
            try conversation.startConversation(
                auth: .publicAgent(id: "test-agent"),
                options: options,
            ),
        ) { error in
            XCTAssertEqual(error as? ConversationError, .connectionFailed("Publish failed"))
        }

        guard case let .failed(.conversationInit(conversationError), _) = conversation.startupState else {
            return XCTFail("Expected conversation init failure state")
        }

        XCTAssertEqual(conversationError, .connectionFailed("Publish failed"))
        XCTAssertEqual(capturedErrors, [.connectionFailed("Publish failed")])
    }

    func testAgentResponseCallbackTogglesFeedbackAvailability() async throws {
        var receivedResponses: [(String, Int)] = []
        var feedbackStates: [Bool] = []

        let options = makeOptions { opts in
            opts.onAgentResponse = { text, eventId in
                receivedResponses.append((text, eventId))
            }
            opts.onCanSendFeedbackChange = { canSend in
                feedbackStates.append(canSend)
            }
        }

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)

        await conversation._testing_handleIncomingEvent(
            .agentResponse(AgentResponseEvent(response: "Hello", eventId: 42)),
        )

        XCTAssertEqual(receivedResponses, [("Hello", 42)])
        XCTAssertEqual(feedbackStates.last, true)

        conversation._testing_setState(.active(.init(agentId: "test")))
        try await conversation.sendFeedback(.like, eventId: 42)
        XCTAssertEqual(feedbackStates.last, false)
    }

    func testVadScoreCallbackReceivesScores() async {
        var vadScores: [Double] = []
        let options = makeOptions { opts in
            opts.onVadScore = { score in
                vadScores.append(score)
            }
        }

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)
        await conversation._testing_handleIncomingEvent(.vadScore(VadScoreEvent(vadScore: 0.87)))

        XCTAssertEqual(vadScores, [0.87])
    }

    func testAgentToolResponseCallbackReceivesEvent() async {
        var capturedToolNames: [String] = []
        let options = makeOptions { opts in
            opts.onAgentToolResponse = { event in
                capturedToolNames.append(event.toolName)
            }
        }

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)
        let toolEvent = AgentToolResponseEvent(toolName: "end_call", toolCallId: "id", toolType: "action", isError: false, eventId: 10)

        await conversation._testing_handleIncomingEvent(.agentToolResponse(toolEvent))

        XCTAssertEqual(capturedToolNames, ["end_call"])
    }

    func testInterruptionCallbackDisablesFeedback() async {
        var interruptionIds: [Int] = []
        var feedbackStates: [Bool] = []

        let options = makeOptions { opts in
            opts.onInterruption = { interruptionIds.append($0) }
            opts.onCanSendFeedbackChange = { feedbackStates.append($0) }
        }

        let conversation = Conversation(dependencyProvider: dependencyProvider, options: options)
        await conversation._testing_handleIncomingEvent(.interruption(InterruptionEvent(eventId: 7)))

        XCTAssertEqual(interruptionIds, [7])
        XCTAssertEqual(feedbackStates.last, false)
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
private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @autoclosure () async throws -> some Any,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in },
    ) async {
        do {
            _ = try await expression()
            XCTFail(message(), file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}

private extension ConversationTests {
    func makeOptions(
        startupConfiguration: ConversationStartupConfiguration = .default,
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        configure: ((inout ConversationOptions) -> Void)? = nil,
    ) -> ConversationOptions {
        var options = ConversationOptions(
            onStartupStateChange: onStartupStateChange,
            startupConfiguration: startupConfiguration,
            onError: { [weak self] error in self?.capturedErrors.append(error) },
        )
        configure?(&options)
        return options
    }
}
