@testable import ElevenLabs
import XCTest

final class MessageTests: XCTestCase {
    func testReceivedMessageCreation() {
        let message = ReceivedMessage(
            id: "msg123",
            timestamp: Date(),
            content: .agentTranscript("Hello from agent")
        )

        XCTAssertEqual(message.id, "msg123")
        XCTAssertEqual(message.content, .agentTranscript("Hello from agent"))
        XCTAssertNotNil(message.timestamp)
    }

    func testSentMessageCreation() {
        let message = SentMessage(
            id: "msg456",
            timestamp: Date(),
            content: .userText("Hello from user")
        )

        XCTAssertEqual(message.id, "msg456")
        XCTAssertEqual(message.content, .userText("Hello from user"))
        XCTAssertNotNil(message.timestamp)
    }

    func testReceivedMessageContentTypes() {
        let agentMessage = ReceivedMessage(
            id: "agent1",
            timestamp: Date(),
            content: .agentTranscript("Agent speaking")
        )

        let userMessage = ReceivedMessage(
            id: "user1",
            timestamp: Date(),
            content: .userTranscript("User speaking")
        )

        XCTAssertEqual(agentMessage.content, .agentTranscript("Agent speaking"))
        XCTAssertEqual(userMessage.content, .userTranscript("User speaking"))
    }

    func testMessageEquality() {
        let timestamp = Date()

        let message1 = ReceivedMessage(
            id: "msg123",
            timestamp: timestamp,
            content: .agentTranscript("Test message")
        )

        let message2 = ReceivedMessage(
            id: "msg123",
            timestamp: timestamp,
            content: .agentTranscript("Test message")
        )

        XCTAssertEqual(message1, message2)
    }

    func testSentMessageEquality() {
        let timestamp = Date()

        let message1 = SentMessage(
            id: "sent123",
            timestamp: timestamp,
            content: .userText("User message")
        )

        let message2 = SentMessage(
            id: "sent123",
            timestamp: timestamp,
            content: .userText("User message")
        )

        XCTAssertEqual(message1, message2)
    }

    func testMessageTimestampAccuracy() {
        let beforeCreation = Date()
        let message = ReceivedMessage(
            id: "timing-test",
            timestamp: Date(),
            content: .userTranscript("Timing test")
        )
        let afterCreation = Date()

        XCTAssertGreaterThanOrEqual(message.timestamp, beforeCreation)
        XCTAssertLessThanOrEqual(message.timestamp, afterCreation)
    }

    func testMessageContentHandling() {
        let emptyMessage = ReceivedMessage(
            id: "empty",
            timestamp: Date(),
            content: .agentTranscript("")
        )

        let longMessage = ReceivedMessage(
            id: "long",
            timestamp: Date(),
            content: .agentTranscript(String(repeating: "a", count: 1000))
        )

        XCTAssertEqual(emptyMessage.content, .agentTranscript(""))
        if case let .agentTranscript(text) = longMessage.content {
            XCTAssertEqual(text.count, 1000)
        } else {
            XCTFail("Expected agentTranscript content")
        }
    }

    func testUnicodeContentHandling() {
        let unicodeMessage = ReceivedMessage(
            id: "unicode",
            timestamp: Date(),
            content: .agentTranscript("Hello 👋 World 🌍 Test 🧪")
        )

        XCTAssertEqual(unicodeMessage.content, .agentTranscript("Hello 👋 World 🌍 Test 🧪"))

        if case let .agentTranscript(text) = unicodeMessage.content {
            XCTAssertTrue(text.contains("👋"))
            XCTAssertTrue(text.contains("🌍"))
            XCTAssertTrue(text.contains("🧪"))
        } else {
            XCTFail("Expected agentTranscript content")
        }
    }
}
