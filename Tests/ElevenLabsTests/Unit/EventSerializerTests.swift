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
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool456")
        let resultString = json["result"] as? String
        XCTAssertNotNil(resultString)
        if let resultString {
            let parsedResult = try JSONSerialization.jsonObject(with: XCTUnwrap(resultString.data(using: .utf8))) as? [String: String]
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
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "client_tool_result")
        XCTAssertEqual(json["tool_call_id"] as? String, "tool789")
        XCTAssertEqual(json["result"] as? String, "42")
        XCTAssertEqual(json["is_error"] as? Bool, false)
    }

    func testSerializeClientToolResultWithBool() throws {
        let event = try OutgoingEvent.clientToolResult(
            ClientToolResultEvent(
                toolCallId: "tool-bool",
                result: true,
                isError: false
            )
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // A boolean must serialize as the JSON literal, not the NSNumber "1".
        XCTAssertEqual(json["result"] as? String, "true")
    }

    func testClientToolResultRejectsNonSerializableValue() {
        struct CustomResult { let value: Int }

        XCTAssertThrowsError(
            try ClientToolResultEvent(toolCallId: "tool-bad", result: CustomResult(value: 7))
        ) { error in
            // Must fail loudly instead of shipping a `String(describing:)` blob.
            guard case .invalidToolResult = error as? ConversationError else {
                return XCTFail("Expected ConversationError.invalidToolResult, got \(error)")
            }
        }
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

    func testSerializeConversationInitWithDynamicVariables() throws {
        // TODO(test): Add a generated-schema fixture test once the local AsyncAPI artifact is refreshed.
        let config = ConversationConfig(
            dynamicVariables: [
                "customer_name": "Ada",
                "account_tier": 2,
                "is_premium": true,
                "tags": ["vip", "beta"],
                "nullable": nil
            ]
        )
        let event = OutgoingEvent.conversationInit(
            ConversationInitEvent(config: config)
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dynamicVariables = try XCTUnwrap(json["dynamic_variables"] as? [String: Any])

        XCTAssertNil(json["custom_llm_extra_body"])
        XCTAssertEqual(dynamicVariables["customer_name"] as? String, "Ada")
        XCTAssertEqual(dynamicVariables["account_tier"] as? Int, 2)
        XCTAssertEqual(dynamicVariables["is_premium"] as? Bool, true)
        XCTAssertEqual(dynamicVariables["tags"] as? [String], ["vip", "beta"])
        XCTAssertTrue(dynamicVariables["nullable"] is NSNull)
    }

    func testSerializeConversationInitTextOnly() throws {
        let event = OutgoingEvent.conversationInit(
            ConversationInitEvent(config: ConversationConfig(textOnly: true))
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let configOverride = try XCTUnwrap(json["conversation_config_override"] as? [String: Any])
        let conversation = try XCTUnwrap(configOverride["conversation"] as? [String: Any])

        XCTAssertEqual(conversation["text_only"] as? Bool, true)
    }

    func testSerializeConversationInitOmitsTextOnlyByDefault() throws {
        let event = OutgoingEvent.conversationInit(
            ConversationInitEvent(config: ConversationConfig())
        )

        let data = try EventSerializer.serializeOutgoingEvent(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let configOverride = json["conversation_config_override"] as? [String: Any]

        XCTAssertNil(configOverride?["conversation"])
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
}

// swiftlint:enable force_cast
