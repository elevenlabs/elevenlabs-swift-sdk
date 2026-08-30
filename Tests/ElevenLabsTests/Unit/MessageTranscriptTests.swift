@testable import ElevenLabs
import XCTest

@MainActor
final class MessageTranscriptTests: XCTestCase {
    func testVoiceAgentMessageProvidesTranscriptWithoutAudioTags() async {
        let conversation = Conversation(dependencyProvider: makeDependencyProvider())

        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(
                response: "[warmly] Hello [clears throat] read the [docs](https://example.com)",
                eventId: 1
            )
        ))

        XCTAssertEqual(
            conversation.messages.last?.content,
            "[warmly] Hello [clears throat] read the [docs](https://example.com)"
        )
        XCTAssertEqual(
            conversation.messages.last?.transcript,
            "Hello read the [docs](https://example.com)"
        )
    }

    func testTextOnlyAgentMessagePreservesAudioTagsInTranscript() async {
        let conversation = Conversation(
            dependencyProvider: makeDependencyProvider(),
            options: ConversationOptions(
                conversationOverrides: ConversationOverrides(textOnly: true)
            )
        )

        await conversation.handleIncomingEvent(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "[happy] Hello", type: .stop, eventId: 2)
        ))

        XCTAssertEqual(conversation.messages.last?.content, "[happy] Hello")
        XCTAssertEqual(conversation.messages.last?.transcript, "[happy] Hello")
    }

    func testUserMessagePreservesBracketedContentInTranscript() async {
        let conversation = Conversation(dependencyProvider: makeDependencyProvider())

        await conversation.handleIncomingEvent(.userTranscript(
            UserTranscriptEvent(transcript: "Read [Chapter 4]", eventId: 3)
        ))

        XCTAssertEqual(conversation.messages.last?.content, "Read [Chapter 4]")
        XCTAssertEqual(conversation.messages.last?.transcript, "Read [Chapter 4]")
    }

    func testAgentResponseCorrectionUpdatesTranscript() async {
        let conversation = Conversation(dependencyProvider: makeDependencyProvider())

        await conversation.handleIncomingEvent(.agentResponse(
            AgentResponseEvent(response: "[sad] The answer is 41", eventId: 4)
        ))
        await conversation.handleIncomingEvent(.agentResponseCorrection(
            AgentResponseCorrectionEvent(
                originalAgentResponse: "[sad] The answer is 41",
                correctedAgentResponse: "[excited] The answer is 42",
                eventId: 4
            )
        ))

        XCTAssertEqual(conversation.messages.last?.content, "[excited] The answer is 42")
        XCTAssertEqual(conversation.messages.last?.transcript, "The answer is 42")
    }

    private func makeDependencyProvider() -> TestDependencyProvider {
        TestDependencyProvider(
            webRTCConnectionManager: MockWebRTCConnectionManager()
        )
    }
}
