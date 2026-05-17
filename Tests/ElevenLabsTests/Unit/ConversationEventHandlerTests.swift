@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationEventHandlerTests: XCTestCase {
    var conversation: Conversation!
    var mockDependencyProvider: TestDependencyProvider!
    var mockTokenService: MockTokenService!
    var mockWebRTCConnectionManager: MockWebRTCConnectionManager!

    override func setUp() async throws {
        mockTokenService = MockTokenService()
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        mockDependencyProvider = TestDependencyProvider(
            tokenService: mockTokenService,
            webRTCConnectionManager: mockWebRTCConnectionManager
        )
        conversation = Conversation(dependencyProvider: mockDependencyProvider)
    }

    override func tearDown() {
        conversation = nil
        mockDependencyProvider = nil
        mockTokenService = nil
        mockWebRTCConnectionManager = nil
    }

    // MARK: - Transcript Tests

    func testHandleUserTranscript() async {
        let expectation = XCTestExpectation(description: "onUserTranscript callback fired")
        let receivedTranscripts = ValueRecorder<(String, Int)>()

        conversation = Conversation(
            dependencyProvider: mockDependencyProvider,
            options: ConversationOptions(
                onUserTranscript: { transcript, eventId in
                    Task { await receivedTranscripts.append((transcript, eventId)) }
                    expectation.fulfill()
                }
            )
        )

        let event = IncomingEvent.userTranscript(UserTranscriptEvent(
            transcript: "Hello world",
            eventId: 123
        ))

        await conversation.handleIncomingEvent(event)

        await fulfillment(of: [expectation], timeout: 1.0)
        let received = await receivedTranscripts.values()
        XCTAssertEqual(received.first?.0, "Hello world")
        XCTAssertEqual(received.first?.1, 123)
        XCTAssertEqual(conversation.messages.last?.content, "Hello world")
        XCTAssertEqual(conversation.messages.last?.role, .user)
    }

    // MARK: - Agent Response Tests

    func testHandleAgentResponse() async {
        let expectation = XCTestExpectation(description: "onAgentResponse callback fired")

        conversation = Conversation(
            dependencyProvider: mockDependencyProvider,
            options: ConversationOptions(
                onAgentResponse: { response, eventId in
                    XCTAssertEqual(response, "I am an AI")
                    XCTAssertEqual(eventId, 456)
                    expectation.fulfill()
                }
            )
        )

        let event = IncomingEvent.agentResponse(AgentResponseEvent(
            response: "I am an AI",
            eventId: 456
        ))

        await conversation.handleIncomingEvent(event)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(conversation.messages.last?.content, "I am an AI")
        XCTAssertEqual(conversation.messages.last?.role, .agent)
        XCTAssertEqual(conversation.lastAgentEventId, 456)
    }

    // MARK: - Interruption Tests

    func testHandleInterruption() async {
        let expectation = XCTestExpectation(description: "onInterruption callback fired")

        conversation = Conversation(
            dependencyProvider: mockDependencyProvider,
            options: ConversationOptions(
                onInterruption: { eventId in
                    XCTAssertEqual(eventId, 789)
                    expectation.fulfill()
                }
            )
        )

        let event = IncomingEvent.interruption(InterruptionEvent(eventId: 789))

        await conversation.handleIncomingEvent(event)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(conversation.agentState, .listening)
    }

    // MARK: - Streaming Tests

    func testHandleAgentChatResponseStream() async {
        // 1. Start
        let startEvent = IncomingEvent.agentChatResponsePart(AgentChatResponsePartEvent(
            text: "Hello",
            type: .start
        ))
        await conversation.handleIncomingEvent(startEvent)
        XCTAssertEqual(conversation.currentStreamingMessage?.content, "Hello")
        XCTAssertEqual(conversation.messages.count, 1)

        // 2. Delta
        let deltaEvent = IncomingEvent.agentChatResponsePart(AgentChatResponsePartEvent(
            text: " World",
            type: .delta
        ))
        await conversation.handleIncomingEvent(deltaEvent)
        XCTAssertEqual(conversation.currentStreamingMessage?.content, "Hello World")
        XCTAssertEqual(conversation.messages.count, 1, "Should update existing message")

        // 3. Stop
        let stopEvent = IncomingEvent.agentChatResponsePart(AgentChatResponsePartEvent(
            text: "!",
            type: .stop
        ))
        await conversation.handleIncomingEvent(stopEvent)
        XCTAssertNil(conversation.currentStreamingMessage)
        XCTAssertEqual(conversation.messages.last?.content, "Hello World!")
    }
}
