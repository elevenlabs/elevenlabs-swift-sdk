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

    func testAgentChatResponsePartMarksMessagePartialUntilStop() async {
        // The callback fires synchronously within handleIncomingEvent, so record
        // synchronously to preserve order (a detached Task would reorder).
        let deltas = OrderedRecorder<(String, AgentChatResponsePartType, Int)>()
        conversation = Conversation(
            dependencyProvider: mockDependencyProvider,
            callbacks: ConversationCallbacks(
                onAgentResponsePart: { text, type, eventId in
                    deltas.append((text, type, eventId))
                }
            )
        )

        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "", type: .start, eventId: 7)
        ))
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "Hel", type: .delta, eventId: 7)
        ))
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "lo", type: .delta, eventId: 7)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "Hello")
        XCTAssertEqual(conversation.messages.last?.isPartial, true)

        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "", type: .stop, eventId: 7)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "Hello")
        XCTAssertEqual(conversation.messages.last?.isPartial, false, ".stop should finalize the streamed message")

        let receivedDeltas = deltas.values
        XCTAssertEqual(receivedDeltas.map(\.0), ["", "Hel", "lo", ""])
        XCTAssertEqual(receivedDeltas.map(\.1), [.start, .delta, .delta, .stop])
        XCTAssertEqual(receivedDeltas.map(\.2), [7, 7, 7, 7])
    }

    func testTentativeUserTranscriptCreatesPartialMessageFinalizedByTranscript() async {
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "hel", eventId: 5)
        ))
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "hello the", eventId: 5)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.role, .user)
        XCTAssertEqual(conversation.messages.last?.content, "hello the")
        XCTAssertEqual(conversation.messages.last?.isPartial, true)

        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "hello there", eventId: 5)
        ))

        XCTAssertEqual(conversation.messages.count, 1, "Final transcript should finalize the partial in place")
        XCTAssertEqual(conversation.messages.last?.content, "hello there")
        XCTAssertEqual(conversation.messages.last?.isPartial, false)
    }

    func testNewTranscriptSupersedesStrayPartialWithDifferentEventId() async {
        // Mirrors an observed sequence: a tentative transcript that never
        // produces a matching final, followed by a new tentative with a higher
        // event id. The stray partial must be superseded in place, not left
        // behind as a second user bubble.
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "Set up.", eventId: 245)
        ))
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "Set up a good test.", eventId: 249)
        ))

        XCTAssertEqual(conversation.messages.count, 1, "A newer tentative must replace the stray partial, not append")
        XCTAssertEqual(conversation.messages.last?.content, "Set up a good test.")
        XCTAssertEqual(conversation.messages.last?.eventId, 249)
        XCTAssertEqual(conversation.messages.last?.isPartial, true)

        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "Set up a good test.", eventId: 249)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "Set up a good test.")
        XCTAssertEqual(conversation.messages.last?.eventId, 249)
        XCTAssertEqual(conversation.messages.last?.isPartial, false)
    }

    func testOutOfOrderUserTranscriptIsStillRecorded() async {
        // A finalized transcript whose event id is older than the latest user
        // message and matches nothing is still recorded (appended in arrival
        // order): finals are canonical and never dropped.
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "current", eventId: 20)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "stale", eventId: 10)
        ))

        XCTAssertEqual(conversation.messages.count, 2, "An unmatched final is recorded, not dropped")
        XCTAssertEqual(conversation.messages.map(\.content), ["current", "stale"])
        XCTAssertEqual(conversation.messages.compactMap(\.eventId), [20, 10])
    }

    func testOutOfOrderAgentResponseIsStillRecorded() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "current", eventId: 20)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "stale", eventId: 10)
        ))

        XCTAssertEqual(conversation.messages.count, 2, "An unmatched final is recorded, not dropped")
        XCTAssertEqual(conversation.messages.map(\.content), ["current", "stale"])
        XCTAssertEqual(conversation.messages.compactMap(\.eventId), [20, 10])
    }

    func testFinalTranscriptClearsStrayPartialFromEarlierTurn() async {
        // A tentative that never finalized, followed directly by a final for a
        // newer turn (no preceding tentative): the final appends and the stray
        // partial is dropped, leaving a single finalized message.
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "umm", eventId: 10)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "what time is it", eventId: 12)
        ))

        XCTAssertEqual(conversation.messages.count, 1, "Stray partial must be dropped when a final is committed")
        XCTAssertEqual(conversation.messages.last?.content, "what time is it")
        XCTAssertEqual(conversation.messages.last?.eventId, 12)
        XCTAssertEqual(conversation.messages.last?.isPartial, false)
    }

    func testNextTentativeClearsStrayPartialBeforeFinalizing() async {
        // A tentative that never finalized, followed by an agent message, then a
        // new turn: the new turn's tentative supersedes the stray partial, and the
        // final finalizes it — leaving no orphaned partial bubble.
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "stray", eventId: 10)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "agent reply", eventId: 11)
        ))
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "real ques", eventId: 12)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "real question", eventId: 12)
        ))

        XCTAssertEqual(conversation.messages.count, 2, "Stray partial must be superseded, not kept")
        XCTAssertEqual(conversation.messages[0].role, .agent)
        XCTAssertEqual(conversation.messages[0].content, "agent reply")
        XCTAssertEqual(conversation.messages[1].role, .user)
        XCTAssertEqual(conversation.messages[1].content, "real question")
        XCTAssertEqual(conversation.messages[1].isPartial, false)
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

    func testAgentResponseOverwritesFinalizedMessageForSameEventId() async {
        // agent_response is canonical for its turn: a later one with the same
        // event id replaces the stored content in place, even after finalization.
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "first final", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "revised final", eventId: 1)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "revised final")
        XCTAssertEqual(conversation.messages.last?.eventId, 1)
        XCTAssertEqual(conversation.messages.last?.isPartial, false)
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

    func testUserTranscriptOverwritesFinalizedMessageForSameEventId() async {
        // A repeated final transcript for the same event id replaces the stored
        // content in place rather than being ignored.
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "first final", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "revised final", eventId: 1)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "revised final")
        XCTAssertEqual(conversation.messages.last?.eventId, 1)
        XCTAssertEqual(conversation.messages.last?.isPartial, false)
    }

    func testUserTranscriptAppendedInArrivalOrderEvenWhenSharingAgentEventId() async {
        // A user transcript that happens to share an agent message's eventId is
        // a distinct message; it is appended in arrival order rather than merged
        // into, or reordered ahead of, the agent message.
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "agent reply", eventId: 5)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "user said this", eventId: 5)
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].role, .agent)
        XCTAssertEqual(conversation.messages[0].content, "agent reply")
        XCTAssertEqual(conversation.messages[1].role, .user)
        XCTAssertEqual(conversation.messages[1].content, "user said this")
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
        XCTAssertFalse(conversation.isAgentSpeaking)
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

    // MARK: - Message Store Consistency Rules
    //
    // These exercise the guarantees the store maintains for any event sequence:
    // 1. Absolute order follows the arrival of finalized transcripts/responses;
    //    messages are only appended (never reordered), so an unmatched final is
    //    recorded even when its event id arrives out of order.
    // 2. At most one in-progress (partial) user transcript exists at a time.
    // 3. User-message event ids are unique (a matching id updates in place).
    // 4. Agent-message event ids are unique (the streamed and finalized message
    //    for a turn coalesce under one id).
    // 5. A partial never overwrites a finalized message; a stale streaming part or
    //    tentative transcript (older than the role's highest event id) is ignored.

    /// Rule 1: the absolute order of messages follows the arrival of the
    /// finalized transcripts/responses; messages are never reordered.
    func testFinalOrderFollowsArrivalOfFinalizedMessages() async {
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "u1", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "a1", eventId: 2)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "u2", eventId: 3)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "a2", eventId: 4)
        ))

        XCTAssertEqual(conversation.messages.map(\.content), ["u1", "a1", "u2", "a2"])
        XCTAssertEqual(conversation.messages[0].role, .user)
        XCTAssertEqual(conversation.messages[1].role, .agent)
        XCTAssertEqual(conversation.messages[2].role, .user)
        XCTAssertEqual(conversation.messages[3].role, .agent)
    }

    /// Rule 2: at most one partial user transcript exists at a time. A new
    /// tentative supersedes the previous one, even while an agent message streams
    /// concurrently.
    func testAtMostOnePartialUserTranscriptWhileAgentStreams() async {
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "u partial", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "a", type: .start, eventId: 2)
        ))
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "u partial revised", eventId: 3)
        ))

        let partialUsers = conversation.messages.filter { $0.role == .user && $0.isPartial }
        XCTAssertEqual(partialUsers.count, 1)
        XCTAssertEqual(partialUsers.first?.content, "u partial revised")
        XCTAssertEqual(partialUsers.first?.eventId, 3)
        // The concurrently-streaming agent partial is untouched.
        XCTAssertEqual(conversation.messages.filter { $0.role == .agent && $0.isPartial }.count, 1)
    }

    /// Rule 3: user-message event ids are unique; in-order finals stay ordered.
    func testUserTranscriptsRemainOrderedAndUniqueByEventId() async {
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "p", eventId: 10)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "first", eventId: 10)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "second", eventId: 20)
        ))
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "third", eventId: 30)
        ))

        let userIds = conversation.messages.filter { $0.role == .user }.compactMap(\.eventId)
        XCTAssertEqual(userIds, [10, 20, 30])
        XCTAssertEqual(userIds, userIds.sorted())
        XCTAssertEqual(Set(userIds).count, userIds.count, "No duplicate user event ids")
    }

    /// Rule 4: agent-message event ids are unique, with the streamed/finalized
    /// message for a turn coalesced under one id.
    func testAgentResponsesRemainOrderedAndUniqueByEventId() async {
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "h", type: .start, eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "i", type: .stop, eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "hi", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "next", eventId: 2)
        ))

        let agentIds = conversation.messages.filter { $0.role == .agent }.compactMap(\.eventId)
        XCTAssertEqual(agentIds, [1, 2])
        XCTAssertEqual(Set(agentIds).count, agentIds.count, "No duplicate agent event ids")
    }

    /// Rule 5: a late partial must not overwrite a finalized agent message.
    func testPartialAgentUpdateDoesNotOverwriteFinalizedMessage() async {
        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "final answer", eventId: 1)
        ))
        XCTAssertEqual(conversation.messages.last?.isPartial, false)

        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " late", type: .delta, eventId: 1)
        ))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.last?.content, "final answer", "Partial must not overwrite finalized content")
        XCTAssertEqual(conversation.messages.last?.isPartial, false, "Partial must not downgrade a finalized message")
    }

    /// Rule 5 (user side): a new tentative for the next turn appends a fresh
    /// partial and must not rewrite an already-finalized user message.
    func testTentativeUserTranscriptDoesNotOverwriteFinalizedMessage() async {
        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "committed", eventId: 1)
        ))
        await conversation.handleIncomingEvent(.tentativeUserTranscript(
            TentativeUserTranscriptEvent(transcript: "typing", eventId: 2)
        ))

        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].content, "committed")
        XCTAssertEqual(conversation.messages[0].isPartial, false)
        XCTAssertEqual(conversation.messages[1].content, "typing")
        XCTAssertEqual(conversation.messages[1].isPartial, true)
    }
}

/// Thread-safe, order-preserving recorder for synchronously-invoked callbacks.
private final class OrderedRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
