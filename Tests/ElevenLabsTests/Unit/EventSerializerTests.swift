// swiftlint:disable force_cast
@testable import ElevenLabs
import XCTest

final class EventSerializerTests: XCTestCase {
    func testSerializeUserMessage() throws {
        let event = OutgoingEvent.userMessage(
            UserMessageEvent(text: "Hello agent")
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "user_message")
        XCTAssertEqual(json["text"] as? String, "Hello agent")
    }

    func testSerializeUserActivity() throws {
        let event = OutgoingEvent.userActivity

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "user_activity")
    }

    func testSerializeClientToolResult() throws {
        let event = OutgoingEvent.clientToolResult(
            ClientToolResultEvent(
                toolCallId: "tool123",
                result: "Sunny, 25°C",
                isError: false
            )
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool123")
        XCTAssertEqual(json["result"] as? String, "Sunny, 25°C")
        XCTAssertEqual(json["is_error"] as? Bool, false)
    }

    func testSerializeClientToolResultWithJSON() throws {
        // Test with dictionary result that will be converted to JSON string
        let dictResult = ["temperature": "25°C", "condition": "Sunny"]
        let event = try OutgoingEvent.clientToolResult(
            ClientToolResultEvent(
                toolCallId: "tool456",
                result: dictResult,
                isError: false
            )
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool456")
        let resultString = json["result"] as? String
        XCTAssertNotNil(resultString)
        if let resultString {
            let parsedResult = try JSONSerialization.jsonObject(with: resultString.data(using: .utf8)!) as? [String: String]
            XCTAssertEqual(parsedResult?["temperature"], "25°C")
            XCTAssertEqual(parsedResult?["condition"], "Sunny")
        }
        XCTAssertEqual(json["is_error"] as? Bool, false)
    }

    func testSerializeClientToolResultWithNumber() throws {
        let event = try OutgoingEvent.clientToolResult(
            ClientToolResultEvent(
                toolCallId: "tool789",
                result: 42,
                isError: false
            )
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool789")
        XCTAssertEqual(json["result"] as? String, "42")
        XCTAssertEqual(json["is_error"] as? Bool, false)
    }

    func testSerializePong() throws {
        let event = OutgoingEvent.pong(PongEvent(eventId: 123))

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "pong")
        XCTAssertEqual(json["event_id"] as? Int, 123)
    }

    func testSerializeConversationInit() throws {
        let config = ConversationConfig()
        let event = OutgoingEvent.conversationInit(
            ConversationInitEvent(config: config)
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "conversation_initiation_client_data")
    }

    func testSerializeContextualUpdate() throws {
        let event = OutgoingEvent.contextualUpdate(
            ContextualUpdateEvent(text: "Updated context")
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "contextual_update")
        XCTAssertEqual(json["text"] as? String, "Updated context")
    }

    func testSerializeFeedback() throws {
        let event = OutgoingEvent.feedback(
            FeedbackEvent(score: .like, eventId: 123)
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "feedback")
        XCTAssertEqual(json["score"] as? String, "like")
        XCTAssertEqual(json["event_id"] as? Int, 123)
    }

    func testSerializeUserAudio() throws {
        let event = OutgoingEvent.userAudio(
            UserAudioEvent(audioChunk: "base64AudioData")
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["user_audio_chunk"] as? String, "base64AudioData")
    }
}

// swiftlint:enable force_cast
