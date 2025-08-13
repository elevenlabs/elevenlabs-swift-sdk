@testable import ElevenLabs
import XCTest

final class EventParserTests: XCTestCase {
    func testParseUserTranscriptEvent() throws {
        let json = """
        {
            "type": "user_transcript",
            "user_transcript": "Hello World"
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .userTranscript(transcript) = event else {
            XCTFail("Expected userTranscript event")
            return
        }

        XCTAssertEqual(transcript.transcript, "Hello World")
    }

    func testParseAgentResponseEvent() throws {
        let json = """
        {
            "type": "agent_response",
            "agent_response": "hello"
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentResponse(response) = event else {
            XCTFail("Expected agentResponse event")
            return
        }

        XCTAssertEqual(response.response, "hello")
    }

    func testParseAudioEvent() throws {
        let json = """
        {
            "type": "audio",
            "audio": {
                "audio_base_64": "123",
                "event_id": 123
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .audio(audio) = event else {
            XCTFail("Expected audio event")
            return
        }

        XCTAssertEqual(audio.eventId, 123)
    }

    func testParseInterruptionEvent() throws {
        let json = """
        {
            "type": "interruption",
            "interruption": {
                "event_id": 123
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .interruption(interruption) = event else {
            XCTFail("Expected interruption event")
            return
        }

        XCTAssertEqual(interruption.eventId, 123)
    }

    func testParseClientToolCallEvent() throws {
        let json = """
        {
            "type": "client_tool_call",
            "client_tool_call": {
                "tool_call_id": "tool123",
                "tool_name": "weather",
                "parameters": {"city": "London"}
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .clientToolCall(toolCall) = event else {
            XCTFail("Expected clientToolCall event")
            return
        }

        XCTAssertEqual(toolCall.toolCallId, "tool123")
        XCTAssertEqual(toolCall.toolName, "weather")
    }

    func testParseAgentToolResponseEvent() throws {
        let json = """
        {
            "type": "agent_tool_response",
            "agent_tool_response": {
                "tool_name": "end_call",
                "tool_call_id": "toolu_vrtx_01Vvmrto87Dvc2RFCoCPMKzx",
                "tool_type": "system",
                "is_error": false
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentToolResponse(toolResponse) = event else {
            XCTFail("Expected agentToolResponse event")
            return
        }

        XCTAssertEqual(toolResponse.toolName, "end_call")
        XCTAssertEqual(toolResponse.toolCallId, "toolu_vrtx_01Vvmrto87Dvc2RFCoCPMKzx")
        XCTAssertEqual(toolResponse.toolType, "system")
        XCTAssertEqual(toolResponse.isError, false)
    }

    func testParseInvalidJSON() {
        let json = "invalid json".data(using: .utf8)!

        XCTAssertThrowsError(try EventParser.parseIncomingEvent(from: json))
    }

    func testParseUnknownEventType() throws {
        let json = """
        {
            "type": "unknown_event",
            "data": {}
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try EventParser.parseIncomingEvent(from: json))
    }

    func testParseMissingRequiredFields() {
        let json = """
        {
            "type": "user_transcript"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try EventParser.parseIncomingEvent(from: json))
    }
}
