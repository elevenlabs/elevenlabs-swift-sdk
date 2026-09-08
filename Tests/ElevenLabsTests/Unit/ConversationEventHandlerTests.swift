@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationEventHandlerTests: XCTestCase {
    var conversation: Conversation!
    var mockDependencyProvider: TestDependencyProvider!
    var mockWebRTCConnectionManager: MockWebRTCConnectionManager!

    override func setUp() async throws {
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        mockDependencyProvider = TestDependencyProvider(
            webRTCConnectionManager: mockWebRTCConnectionManager
        )
        conversation = Conversation(dependencyProvider: mockDependencyProvider)
    }

    override func tearDown() {
        conversation = nil
        mockDependencyProvider = nil
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
            eventId: 456,
            responseId: "response-1"
        ))

        await conversation.handleIncomingEvent(event)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(conversation.messages.last?.content, "I am an AI")
        XCTAssertEqual(conversation.messages.last?.role, .agent)
        XCTAssertEqual(conversation.messages.last?.eventId, 456)
        XCTAssertEqual(conversation.lastAgentEventId, 456)
    }

    func testAgentResponseFinalizesStreamedMessageInsteadOfDuplicating() async {
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 42, responseId: "response-1")
        ))
        let id = conversation.messages[0].id
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " World", type: .stop, eventId: 42, responseId: "response-1")
        ))
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(
            conversation.messages.last?.eventId,
            42,
            "Streamed message should already carry the turn's eventId"
        )

        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "Hello World", eventId: 42, responseId: "response-1")
        ))

        XCTAssertEqual(
            conversation.messages.count,
            1,
            "agent_response must not duplicate the streamed message"
        )
        XCTAssertEqual(conversation.messages.last?.content, "Hello World")
        XCTAssertEqual(conversation.messages.last?.eventId, 42)
        XCTAssertEqual(conversation.messages[0].id, id, "Message identity must stay stable for SwiftUI diffing")
    }

    func testAgentResponseAppendsWhenNoStreamedMessagePending() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "First", eventId: 1, responseId: "response-1")
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "Second", eventId: 2, responseId: "response-2")
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].eventId, 1)
        XCTAssertEqual(conversation.messages[1].eventId, 2)
    }

    // MARK: - Response ID Reconciliation

    func testResponsesSharingEventIdStayDistinct() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "Before the tool", eventId: 42, responseId: "response-1")
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "After the tool", eventId: 42, responseId: "response-2")
        ))

        XCTAssertEqual(
            conversation.messages.count,
            2,
            "Responses on either side of a tool call share an eventId but are distinct messages"
        )
        XCTAssertEqual(conversation.messages[0].content, "Before the tool")
        XCTAssertEqual(conversation.messages[1].content, "After the tool")
    }

    func testStreamsSharingEventIdReconcileSeparately() async {
        for part in [
            AgentChatResponsePartEvent(text: "", type: .start, eventId: 42, responseId: "response-1"),
            AgentChatResponsePartEvent(text: "Before the tool", type: .delta, eventId: 42, responseId: "response-1"),
            AgentChatResponsePartEvent(text: "", type: .stop, eventId: 42, responseId: "response-1"),
            AgentChatResponsePartEvent(text: "", type: .start, eventId: 42, responseId: "response-2"),
            AgentChatResponsePartEvent(text: "After the tool", type: .delta, eventId: 42, responseId: "response-2"),
            AgentChatResponsePartEvent(text: "", type: .stop, eventId: 42, responseId: "response-2")
        ] {
            await conversation.handleIncomingEvent(.agentChatResponsePart(part))
        }

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].content, "Before the tool")
        XCTAssertEqual(conversation.messages[1].content, "After the tool")
    }

    func testLatePartDoesNotMutateFinalizedResponse() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "final answer", eventId: 1, responseId: "response-1")
        ))
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " late", type: .delta, eventId: 1, responseId: "response-1")
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages[0].content, "final answer")
    }

    // MARK: - Agent Response Correction Tests

    func testAgentResponseCorrectionUpdatesStoredMessage() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "the answr is 41", eventId: 7, responseId: "response-1")
        ))
        XCTAssertEqual(conversation.messages.last?.content, "the answr is 41")

        await conversation.handleIncomingEvent(.agentResponseCorrection(
            AgentResponseCorrectionEvent(
                originalAgentResponse: "the answr is 41",
                correctedAgentResponse: "the answer is 42",
                eventId: 7,
                responseId: "response-1"
            )
        ))

        XCTAssertEqual(
            conversation.messages.count,
            1,
            "Correction should update in place, not append"
        )
        XCTAssertEqual(conversation.messages.last?.content, "the answer is 42")
        XCTAssertEqual(conversation.messages.last?.eventId, 7)
    }

    func testAgentResponseCorrectionTargetsItsOwnResponse() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "First", eventId: 9, responseId: "response-1")
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "Second", eventId: 9, responseId: "response-2")
        ))

        await conversation.handleIncomingEvent(.agentResponseCorrection(
            AgentResponseCorrectionEvent(
                originalAgentResponse: "First",
                correctedAgentResponse: "Corrected",
                eventId: 9,
                responseId: "response-1"
            )
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].content, "Corrected")
        XCTAssertEqual(conversation.messages[1].content, "Second")
    }

    func testAgentResponseCorrectionWithUnknownResponseIdAppends() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "kept as-is", eventId: 100, responseId: "response-1")
        ))

        await conversation.handleIncomingEvent(.agentResponseCorrection(
            AgentResponseCorrectionEvent(
                originalAgentResponse: "x",
                correctedAgentResponse: "y",
                eventId: 999,
                responseId: "response-2"
            )
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].content, "kept as-is")
        XCTAssertEqual(conversation.messages[0].eventId, 100)
        XCTAssertEqual(conversation.messages[1].content, "y")
        XCTAssertEqual(conversation.messages[1].eventId, 999)
    }

    // MARK: - User Transcript eventId

    func testUserTranscriptCarriesEventId() async {
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "hi", eventId: 11)
        ))
        XCTAssertEqual(conversation.messages.last?.eventId, 11)
        XCTAssertEqual(conversation.messages.last?.role, .user)
    }

    func testUserTranscriptInsertedBeforeAgentMessageWithSameEventId() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "agent reply", eventId: 5, responseId: "response-1")
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "user said this", eventId: 5)
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].role, .user)
        XCTAssertEqual(conversation.messages[0].content, "user said this")
        XCTAssertEqual(conversation.messages[1].role, .agent)
        XCTAssertEqual(conversation.messages[1].content, "agent reply")
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
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 13, responseId: "response-1")
        ))
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "Hello")
        XCTAssertEqual(conversation.messages.last?.eventId, 13)

        // 2. Delta
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " World", type: .delta, eventId: 13, responseId: "response-1")
        ))
        XCTAssertEqual(conversation.messages.count, 1, "Should update existing message")
        XCTAssertEqual(conversation.messages.last?.content, "Hello World")

        // 3. Stop
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "!", type: .stop, eventId: 13, responseId: "response-1")
        ))
        XCTAssertEqual(conversation.messages.last?.content, "Hello World!")
        XCTAssertEqual(conversation.messages.last?.eventId, 13)
    }
}
