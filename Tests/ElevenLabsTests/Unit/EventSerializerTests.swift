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

    func testSerializeConversationInitDynamicVariablesNativeJSONTypes() throws {
        let config = ConversationConfig(
            dynamicVariables: [
                "customer_name": .string("John Doe"),
                "user_id": .int(5),
                "is_premium": .boolean(true),
                "account_balance": .number(5000.50)
            ]
        )
        let event = OutgoingEvent.conversationInit(
            ConversationInitEvent(config: config)
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "conversation_initiation_client_data")

        let vars = try XCTUnwrap(json["dynamic_variables"] as? [String: Any])
        XCTAssertEqual(vars["customer_name"] as? String, "John Doe")
        XCTAssertEqual(vars["user_id"] as? Int, 5)
        XCTAssertNil(vars["user_id"] as? String)
        XCTAssertEqual(vars["is_premium"] as? Bool, true)
        XCTAssertNil(vars["is_premium"] as? String)
        XCTAssertEqual(vars["account_balance"] as? Double, 5000.50)
        XCTAssertNil(vars["account_balance"] as? String)

        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"user_id\":5"), "int should serialize as a JSON number: \(raw)")
        XCTAssertFalse(raw.contains("\"user_id\":\"5\""))
        XCTAssertTrue(raw.contains("\"is_premium\":true"), "bool should serialize as a JSON bool: \(raw)")
        XCTAssertFalse(raw.contains("\"is_premium\":\"true\""))
        XCTAssertFalse(raw.contains("\"account_balance\":\"5000"))
        XCTAssertTrue(
            raw.contains("\"account_balance\":5000.5"),
            "double should serialize as a JSON number: \(raw)"
        )
    }
}

// swiftlint:enable force_cast
