// swiftlint:disable force_cast
@testable import ElevenLabs
import XCTest

final class EventSerializerTests: XCTestCase {
    func testSerializeUserMessage() throws {
        let event = OutgoingEvent.userMessage(
            UserMessageEvent(text: "Hello agent")
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "user_message")
        XCTAssertEqual(json["text"] as? String, "Hello agent")
    }

    func testSerializeUserActivity() throws {
        let event = OutgoingEvent.userActivity

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

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
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool123")
        XCTAssertEqual(json["result"] as? String, "Sunny, 25°C")
        XCTAssertEqual(json["is_error"] as? Bool, false)
    }

    func testSerializeClientToolResultWithErrorType() throws {
        let event = OutgoingEvent.clientToolResult(
            ClientToolResultEvent(
                toolCallId: "tool-rejected",
                result: "User denied location access",
                errorType: .userRejected
            )
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool-rejected")
        // errorType implies is_error even when not set explicitly.
        XCTAssertEqual(json["is_error"] as? Bool, true)
        XCTAssertEqual(json["error_type"] as? String, "user_rejected")
    }

    func testSerializePong() throws {
        let event = OutgoingEvent.pong(PongEvent(eventId: 123))

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "pong")
        XCTAssertEqual(json["event_id"] as? Int, 123)
    }

    func testSerializeConversationInit() throws {
        let config = ConversationConfig()
        let event = OutgoingEvent.conversationInit(
            ConversationInitEvent(config: config)
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "conversation_initiation_client_data")
    }

    func testConversationInitSendsTypedValues() throws {
        let config = ConversationConfig(
            customLlmExtraBody: ["temperature": 0.5, "max_tokens": 150, "response_format": ["type": "json_object"]],
            dynamicVariables: [
                "name": "John", "user_id": 12345, "balance": 5000.5, "is_premium": true,
                "tags": ["a", 1], "address": ["city": "Paris", "zip": 75001], "missing": .null
            ]
        )
        let data = try EventSerializer.serializeOutgoingEvent(.conversationInit(ConversationInitEvent(config: config)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let variables = try XCTUnwrap(json["dynamic_variables"] as? [String: Any])
        XCTAssertEqual(variables["name"] as? String, "John")
        XCTAssertEqual(variables["user_id"] as? Int, 12345)
        XCTAssertEqual(variables["balance"] as? Double, 5000.5)
        XCTAssertEqual(variables["is_premium"] as? Bool, true)
        XCTAssertEqual(variables["tags"] as? [AnyHashable], ["a", 1])
        let address = try XCTUnwrap(variables["address"] as? [String: Any])
        XCTAssertEqual(address["city"] as? String, "Paris")
        XCTAssertEqual(address["zip"] as? Int, 75001)
        XCTAssertTrue(variables["missing"] is NSNull)

        let body = try XCTUnwrap(json["custom_llm_extra_body"] as? [String: Any])
        XCTAssertEqual(body["temperature"] as? Double, 0.5)
        XCTAssertEqual(body["max_tokens"] as? Int, 150)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testDynamicVariableBooleanIsNotSentAsNumber() throws {
        let config = ConversationConfig(dynamicVariables: ["flag": true, "count": 1])
        let data = try EventSerializer.serializeOutgoingEvent(.conversationInit(ConversationInitEvent(config: config)))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains(#""flag":true"#))
        XCTAssertTrue(text.contains(#""count":1"#))
    }

    func testSerializeContextualUpdate() throws {
        let event = OutgoingEvent.contextualUpdate(
            ContextualUpdateEvent(text: "Updated context")
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "contextual_update")
        XCTAssertEqual(json["text"] as? String, "Updated context")
    }

    func testSerializeFeedback() throws {
        let event = OutgoingEvent.feedback(
            FeedbackEvent(score: .like, eventId: 123)
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "feedback")
        XCTAssertEqual(json["score"] as? String, "like")
        XCTAssertEqual(json["event_id"] as? Int, 123)
    }

    func testSerializeUserAudio() throws {
        let event = OutgoingEvent.userAudio(
            UserAudioEvent(audioChunk: "base64AudioData")
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["user_audio_chunk"] as? String, "base64AudioData")
    }
}

// swiftlint:enable force_cast
