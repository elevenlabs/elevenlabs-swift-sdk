// swiftlint:disable line_length force_unwrapping
@testable import ElevenLabs
import XCTest

final class EventParserTests: XCTestCase {
    func testParseUserTranscriptEvent() throws {
        let json = """
        {"user_transcription_event":{"user_transcript":"Hey, how are you?","event_id":26},"type":"user_transcript"}
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .userTranscript(transcript) = event else {
            XCTFail("Expected userTranscript event")
            return
        }

        XCTAssertEqual(transcript.transcript, "Hey, how are you?")
    }

    func testParseAgentResponseEvent() throws {
        let json = """
        {"agent_response_event":{"agent_response":"Hello! How can I help you today?","event_id":1},"type":"agent_response"}
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentResponse(response) = event else {
            XCTFail("Expected agentResponse event")
            return
        }

        XCTAssertEqual(response.response, "Hello! How can I help you today?")
    }

    func testParseAudioEvent() throws {
        let json = """
        {"audio_event":{"audio_base_64":"audio","event_id":26,"alignment":{"chars":["I","'","m"," ","d","o","i","n","g"," ","w","e","l","l",","," ","t","h","a","n","k"," ","y","o","u","!"," ","H","o","w"," ","c","a","n"," ","I"," ","a","s","s","i","s","t"," ","y","o","u"," ","t","o","d","a","y","?"," "],"char_start_times_ms":[0,93,151,197,244,279,337,395,418,453,499,534,592,639,673,708,731,755,789,824,882,929,987,1010,1045,1103,1184,1265,1324,1382,1416,1463,1498,1533,1567,1614,1649,1683,1707,1730,1776,1834,1881,1916,1950,1974,1997,2020,2055,2090,2136,2194,2241,2357,2415],"char_durations_ms":[93,58,46,47,35,58,58,23,35,46,35,58,47,34,35,23,24,34,35,58,47,58,23,35,58,81,81,59,58,34,47,35,35,34,47,35,34,24,23,46,58,47,35,34,24,23,23,35,35,46,58,47,116,58,279]}},"type":"audio"}
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .audio(audio) = event else {
            XCTFail("Expected audio event")
            return
        }

        XCTAssertEqual(audio.eventId, 26)
    }

    func testParseAudioEventWithTimestamps() throws {
        let json = """
        {"audio_event":{"audio_base_64":"AAADAAIAAQABAP///v/+/////f/9//3///8BAAAAAQAB","event_id":1,"alignment":{"chars":["H","e","l","l","o","!"," ","H","o","w"," ","c","a","n"," ","I"," ","h","e","l","p"," ","y","o","u"," ","t","o","d","a","y","?"," "],"char_start_times_ms":[0,93,151,186,244,337,372,395,430,464,499,546,569,615,639,685,720,755,789,813,848,882,917,940,964,998,1033,1057,1091,1149,1184,1277,1312],"char_durations_ms":[93,58,35,58,93,35,23,35,34,35,47,23,46,24,46,35,35,34,24,35,34,35,23,24,34,35,24,34,58,35,93,35,174]}},"type":"audio"}
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .audio(audio) = event else {
            XCTFail("Expected audio event")
            return
        }

        XCTAssertEqual(audio.eventId, 1)
    }

    func testParseInterruptionEvent() throws {
        let json = """
        {
            "type": "interruption",
            "interruption_event": {
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
                "parameters": {"city": "London"},
                "event_id": 123
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

    func testParseMCPConnectionStatusEvent() throws {
        let json = """
        {"mcp_connection_status":{"integrations":[{"integration_id":"1REt5AalBdQAof1Ksu6R","integration_type":"mcp_server","is_connected":true,"tool_count":5}]},"type":"mcp_connection_status"}
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .mcpConnectionStatus(mcpConnectionStatus) = event else {
            XCTFail("Expected mcpToolCall event")
            return
        }

        XCTAssertEqual(mcpConnectionStatus.integrations.count, 1)
    }

    func testParseMcpToolCallEvent() throws {
        let json = """
        {"mcp_tool_call":{"service_id":"1REt5AalBdQAof1Ksu6R","tool_call_id":"tlcal_6901k6djmbymfbe9rg5ygw62tpwe","tool_name":"search_shop_catalog","tool_description":null,"parameters":{"context":"customer browsing","limit":5,"query":"products"},"timestamp":"2025-09-30T15:07:37.300191+00:00","state":"loading"},"type":"mcp_tool_call"}
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .mcpToolCall(toolCall) = event else {
            XCTFail("Expected mcpToolCall event")
            return
        }

        XCTAssertEqual(toolCall.toolCallId, "tlcal_6901k6djmbymfbe9rg5ygw62tpwe")
        XCTAssertEqual(toolCall.toolName, "search_shop_catalog")
    }

    func testParseAgentToolResponseEvent() throws {
        let json = """
        {
            "type": "agent_tool_response",
            "agent_tool_response": {
                "tool_name": "end_call",
                "tool_call_id": "toolu_vrtx_01Vvmrto87Dvc2RFCoCPMKzx",
                "tool_type": "system",
                "is_error": false,
                "event_id": 123
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

    func testParseAgentChatResponsePartStart() throws {
        let json = """
        {
            "type": "agent_chat_response_part",
            "text_response_part": {
                "text": "",
                "type": "start"
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentChatResponsePart(part) = event else {
            XCTFail("Expected agentChatResponsePart event")
            return
        }

        XCTAssertEqual(part.text, "")
        XCTAssertEqual(part.type, .start)
    }

    func testParseAgentChatResponsePartDelta() throws {
        let json = """
        {
            "type": "agent_chat_response_part",
            "text_response_part": {
                "text": "Hello",
                "type": "delta"
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentChatResponsePart(part) = event else {
            XCTFail("Expected agentChatResponsePart event")
            return
        }

        XCTAssertEqual(part.text, "Hello")
        XCTAssertEqual(part.type, .delta)
    }

    func testParseAgentChatResponsePartStop() throws {
        let json = """
        {
            "type": "agent_chat_response_part",
            "text_response_part": {
                "text": "",
                "type": "stop"
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentChatResponsePart(part) = event else {
            XCTFail("Expected agentChatResponsePart event")
            return
        }

        XCTAssertEqual(part.text, "")
        XCTAssertEqual(part.type, .stop)
    }

    func testParseAgentChatResponsePartDefaultsToDelta() throws {
        let json = """
        {
            "type": "agent_chat_response_part",
            "text_response_part": {
                "text": "Test"
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentChatResponsePart(part) = event else {
            XCTFail("Expected agentChatResponsePart event")
            return
        }

        XCTAssertEqual(part.text, "Test")
        XCTAssertEqual(part.type, .delta)
    }

    func testParseAgentResponseMetadataEvent() throws {
        let json = """
        {
            "type": "agent_response_metadata",
            "agent_response_metadata_event": {
                "event_id": 456,
                "metadata": {"custom_field": "custom_value"}
            }
        }
        """.data(using: .utf8)!

        let event = try EventParser.parseIncomingEvent(from: json)

        guard case let .agentResponseMetadata(metadata) = event else {
            XCTFail("Expected agentResponseMetadata event")
            return
        }

        XCTAssertEqual(metadata.eventId, 456)
        XCTAssertFalse(metadata.metadataData.isEmpty)
    }
}

// swiftlint:enable line_length force_unwrapping
