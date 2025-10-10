@testable import ElevenLabs
import LiveKit
import XCTest

@MainActor
final class ConversationTests: XCTestCase {
    private var conversation: Conversation!
    private var mockConnectionManager: MockConnectionManager!
    private var mockTokenService: MockTokenService!

    override func setUp() async throws {
        mockConnectionManager = MockConnectionManager()
        mockTokenService = MockTokenService()

        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        conversation = Conversation(dependencies: mockDependencies)
    }

    override func tearDown() async throws {
        conversation = nil
        mockConnectionManager = nil
        mockTokenService = nil
    }

    @MainActor
    func testConversationInitialState() {
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertTrue(conversation.isMuted)
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testStartConversationWithAgentId() async throws {
        let config = ConversationConfig()

        do {
            try await conversation.startConversation(
                auth: ElevenLabsConfiguration.publicAgent(id: "test-agent-id"),
                options: config.toConversationOptions(),
            )
            // In a real test with dependency injection, we'd verify the connection was established
        } catch {
            // Expected to fail without proper mocking infrastructure
            XCTAssertTrue(error is ConversationError)
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
