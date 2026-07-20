@testable import ElevenLabs
import Foundation
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
            callbacks: ConversationCallbacks(
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
            callbacks: ConversationCallbacks(
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
        XCTAssertEqual(conversation.messages.last?.eventId, 456)
    }

    func testAgentResponseFinalizesStreamedMessageInsteadOfDuplicating() async {
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 42)
        ))
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " World", type: .stop, eventId: 42)
        ))
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(
            conversation.messages.last?.eventId,
            42,
            "Streamed message should already carry the turn's eventId"
        )

        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "Hello World", eventId: 42)
        ))

        XCTAssertEqual(
            conversation.messages.count,
            1,
            "agent_response must not duplicate the streamed message"
        )
        XCTAssertEqual(conversation.messages.last?.content, "Hello World")
        XCTAssertEqual(conversation.messages.last?.eventId, 42)
    }

    func testAgentResponseAppendsWhenNoStreamedMessagePending() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "First", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "Second", eventId: 2)
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].eventId, 1)
        XCTAssertEqual(conversation.messages[1].eventId, 2)
    }

    // MARK: - Agent Response Correction Tests

    func testAgentResponseCorrectionUpdatesStoredMessage() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "the answr is 41", eventId: 7)
        ))
        XCTAssertEqual(conversation.messages.last?.content, "the answr is 41")

        await conversation.handleIncomingEvent(.agentResponseCorrection(
            AgentResponseCorrectionEvent(
                originalAgentResponse: "the answr is 41",
                correctedAgentResponse: "the answer is 42",
                eventId: 7
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

    func testAgentResponseCorrectionWithUnknownEventIdAppends() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "kept as-is", eventId: 100)
        ))

        await conversation.handleIncomingEvent(.agentResponseCorrection(
            AgentResponseCorrectionEvent(
                originalAgentResponse: "x",
                correctedAgentResponse: "y",
                eventId: 999
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
            AgentResponseEvent(response: "agent reply", eventId: 5)
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
            callbacks: ConversationCallbacks(
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
            AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 13)
        ))
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "Hello")
        XCTAssertEqual(conversation.messages.last?.eventId, 13)

        // 2. Delta
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " World", type: .delta, eventId: 13)
        ))
        XCTAssertEqual(conversation.messages.count, 1, "Should update existing message")
        XCTAssertEqual(conversation.messages.last?.content, "Hello World")

        // 3. Stop
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "!", type: .stop, eventId: 13)
        ))
        XCTAssertEqual(conversation.messages.last?.content, "Hello World!")
        XCTAssertEqual(conversation.messages.last?.eventId, 13)
    }

    // MARK: - End Call

    func testAutomaticEndCallHandling() async {
        await conversation.handleIncomingEvent(.agentToolResponse(AgentToolResponseEvent(
            toolName: "end_call", toolCallId: "id", toolType: "action", isError: false, eventId: 1
        )))

        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
    }

    // MARK: - Audio Alignment

    func testAudioAlignmentCallback() async {
        let receivedAlignment = expectation(description: "Audio alignment callback")
        conversation = Conversation(
            dependencyProvider: mockDependencyProvider,
            callbacks: ConversationCallbacks(onAudioAlignment: { alignment in
                XCTAssertEqual(alignment.chars, ["H", "e", "l", "l", "o"])
                receivedAlignment.fulfill()
            })
        )

        let alignment = AudioAlignment(
            chars: ["H", "e", "l", "l", "o"],
            charStartTimesMs: [0, 100, 200, 300, 400],
            charDurationsMs: [100, 100, 100, 100, 100]
        )
        await conversation.handleIncomingEvent(
            .audio(AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment))
        )
        await fulfillment(of: [receivedAlignment], timeout: 1)
    }

    // MARK: - Client Tool Calls

    func testClientToolCallIsQueuedInPendingToolCalls() async throws {
        let toolCall = try ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_123",
            parametersData: JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1,
            expectsResponse: false
        )
        await conversation.handleIncomingEvent(.clientToolCall(toolCall))

        XCTAssertEqual(conversation.pendingToolCalls.count, 1)
        XCTAssertEqual(conversation.pendingToolCalls.first?.toolCallId, "call_123")
    }
}
