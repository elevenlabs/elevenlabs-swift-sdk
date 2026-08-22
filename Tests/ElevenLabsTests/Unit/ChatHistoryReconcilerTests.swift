@testable import ElevenLabs
import Foundation
import XCTest

final class ChatHistoryReconcilerTests: XCTestCase {
    func testFullResponsesWithSameEventIdStayDistinct() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentResponseEvent(
            response: "Before the tool",
            eventId: 42,
            responseId: "response-1"
        ))
        reconciler.receive(AgentResponseEvent(
            response: "After the tool",
            eventId: 42,
            responseId: "response-2"
        ))

        XCTAssertEqual(messages(in: reconciler).map(\.id), ["response-1", "response-2"])
    }

    func testStreamsWithSameEventIdReconcileInOrder() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentChatResponsePartEvent(
            text: "",
            type: .start,
            eventId: 42,
            responseId: "response-1"
        ))
        reconciler.receive(AgentChatResponsePartEvent(
            text: "Before the tool",
            type: .delta,
            eventId: 42,
            responseId: "response-1"
        ))
        let firstId = messages(in: reconciler)[0].id
        let firstItemId = reconciler.items[0].id
        reconciler.receive(AgentResponseEvent(
            response: "Before the tool",
            eventId: 42,
            responseId: "response-1"
        ))

        reconciler.receive(AgentChatResponsePartEvent(
            text: "",
            type: .start,
            eventId: 42,
            responseId: "response-2"
        ))
        reconciler.receive(AgentChatResponsePartEvent(
            text: "After the tool",
            type: .delta,
            eventId: 42,
            responseId: "response-2"
        ))
        reconciler.receive(AgentChatResponsePartEvent(
            text: "",
            type: .stop,
            eventId: 42,
            responseId: "response-2"
        ))
        let secondId = messages(in: reconciler)[1].id
        reconciler.receive(AgentResponseEvent(
            response: "After the tool",
            eventId: 42,
            responseId: "response-2"
        ))

        let messages = messages(in: reconciler)
        XCTAssertEqual(messages.map(\.id), [firstId, secondId])
        XCTAssertEqual(reconciler.items[0].id, firstItemId)
        XCTAssertEqual(messages.map(\.isFinal), [true, true])
        XCTAssertEqual(messages.map(\.id), ["response-1", "response-2"])
    }

    func testDuplicateFullResponseUpdatesByResponseId() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentResponseEvent(
            response: "Initial",
            eventId: 1,
            responseId: "response-1"
        ))
        let id = messages(in: reconciler)[0].id
        reconciler.receive(AgentResponseEvent(
            response: "Updated",
            eventId: 1,
            responseId: "response-1"
        ))

        let messages = messages(in: reconciler)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, id)
        XCTAssertEqual(messages[0].content, "Updated")
    }

    func testStoppedPartOnlyStreamRemainsStreaming() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentChatResponsePartEvent(
            text: "",
            type: .start,
            eventId: 1,
            responseId: "response-1"
        ))
        reconciler.receive(AgentChatResponsePartEvent(
            text: "Partial",
            type: .delta,
            eventId: 1,
            responseId: "response-1"
        ))
        reconciler.receive(AgentChatResponsePartEvent(
            text: "",
            type: .stop,
            eventId: 1,
            responseId: "response-1"
        ))

        XCTAssertEqual(messages(in: reconciler).first?.isFinal, false)
    }

    func testLatePartDoesNotMutateFinalizedMessage() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentResponseEvent(
            response: "final answer",
            eventId: 1,
            responseId: "response-1"
        ))
        reconciler.receive(AgentChatResponsePartEvent(
            text: " late",
            type: .delta,
            eventId: 1,
            responseId: "response-1"
        ))

        let message = messages(in: reconciler)[0]
        XCTAssertEqual(messages(in: reconciler).count, 1)
        XCTAssertEqual(message.content, "final answer")
        XCTAssertTrue(message.isFinal)
    }

    func testTentativeTranscriptFinalizesWithStableIdentity() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(TentativeUserTranscriptEvent(transcript: "Hello", eventId: 1))
        let id = messages(in: reconciler)[0].id
        reconciler.receive(UserTranscriptEvent(transcript: "Hello", eventId: 1))

        let message = messages(in: reconciler)[0]
        XCTAssertEqual(message.id, id)
        XCTAssertEqual(message.content, "Hello")
        XCTAssertTrue(message.isFinal)
    }

    func testRepeatedFinalTranscriptUpdatesByEventId() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(UserTranscriptEvent(transcript: "first final", eventId: 1))
        let id = messages(in: reconciler)[0].id
        reconciler.receive(UserTranscriptEvent(transcript: "revised final", eventId: 1))

        let messages = messages(in: reconciler)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, id)
        XCTAssertEqual(messages[0].content, "revised final")
        XCTAssertTrue(messages[0].isFinal)
    }

    func testNewTentativeTranscriptSupersedesStaleOne() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(TentativeUserTranscriptEvent(transcript: "Old", eventId: 1))
        reconciler.receive(TentativeUserTranscriptEvent(transcript: "New", eventId: 2))

        let messages = messages(in: reconciler)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "New")
        XCTAssertEqual(messages[0].eventId, 2)
    }

    func testAgentToolResponsesProduceOneItemPerCall() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentToolResponseEvent(
            toolName: "search",
            toolCallId: "tool-1",
            toolType: "webhook",
            isError: false,
            eventId: 7
        ))
        reconciler.receive(AgentToolResponseEvent(
            toolName: "lookup",
            toolCallId: "tool-2",
            toolType: "webhook",
            isError: true,
            eventId: 7
        ))

        let tools = toolCalls(in: reconciler)
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools.map(\.toolCallId), ["tool-1", "tool-2"])
        XCTAssertEqual(tools.map(\.toolName), ["search", "lookup"])
    }

    func testCorrectionUpdatesMatchingMessage() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentResponseEvent(
            response: "First",
            eventId: 9,
            responseId: "response-1"
        ))
        reconciler.receive(AgentResponseEvent(
            response: "Second",
            eventId: 9,
            responseId: "response-2"
        ))
        reconciler.receive(AgentResponseCorrectionEvent(
            originalAgentResponse: "First",
            correctedAgentResponse: "Corrected",
            eventId: 9,
            responseId: "response-1"
        ))

        let messages = messages(in: reconciler)
        XCTAssertEqual(messages[0].content, "Corrected")
        XCTAssertEqual(messages[1].content, "Second")
    }

    func testEmptyCorrectionKeepsIdentity() {
        var reconciler = ChatHistoryReconciler()

        reconciler.receive(AgentResponseEvent(
            response: "Gone",
            eventId: 3,
            responseId: "response-1"
        ))
        let id = messages(in: reconciler)[0].id
        reconciler.receive(AgentResponseCorrectionEvent(
            originalAgentResponse: "Gone",
            correctedAgentResponse: "",
            eventId: 3,
            responseId: "response-1"
        ))

        let messages = messages(in: reconciler)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, id)
        XCTAssertEqual(messages[0].content, "")
        XCTAssertTrue(messages[0].isFinal)
    }

    private func messages(in reconciler: ChatHistoryReconciler) -> [Message] {
        reconciler.items.compactMap(\.message)
    }

    private func toolCalls(in reconciler: ChatHistoryReconciler) -> [ConversationToolCall] {
        reconciler.items.compactMap(\.toolCall)
    }
}
