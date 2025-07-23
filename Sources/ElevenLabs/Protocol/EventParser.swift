import Foundation

enum EventParser {
    /// Parse incoming JSON data into an IncomingEvent
    static func parseIncomingEvent(from data: Data) throws -> IncomingEvent? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return nil
        }

        switch type {
        case "user_transcript":
            if let event = json["user_transcription_event"] as? [String: Any],
               let transcript = event["user_transcript"] as? String
            {
                return .userTranscript(UserTranscriptEvent(transcript: transcript))
            }

        case "agent_response":
            if let event = json["agent_response_event"] as? [String: Any],
               let response = event["agent_response"] as? String
            {
                return .agentResponse(AgentResponseEvent(response: response))
            }

        case "agent_response_correction":
            if let event = json["agent_response_correction_event"] as? [String: Any],
               let correctedUpTo = event["corrected_up_to"] as? String
            {
                return .agentResponseCorrection(AgentResponseCorrectionEvent(correctedUpTo: correctedUpTo))
            }

        case "audio":
            if let event = json["audio_event"] as? [String: Any],
               let audioBase64 = event["audio_base_64"] as? String,
               let eventId = event["event_id"] as? Int
            {
                return .audio(AudioEvent(audioBase64: audioBase64, eventId: eventId))
            }

        case "interruption":
            if let event = json["interruption_event"] as? [String: Any],
               let eventId = event["event_id"] as? Int
            {
                return .interruption(InterruptionEvent(eventId: eventId))
            }

        case "internal_tentative_agent_response":
            if let event = json["tentative_agent_response_internal_event"] as? [String: Any],
               let response = event["tentative_agent_response"] as? String
            {
                return .tentativeAgentResponse(TentativeAgentResponseEvent(tentativeResponse: response))
            }

        case "conversation_initiation_metadata":
            if let event = json["conversation_initiation_metadata_event"] as? [String: Any],
               let conversationId = event["conversation_id"] as? String,
               let agentFormat = event["agent_output_audio_format"] as? String
            {
                let userFormat = event["user_input_audio_format"] as? String
                return .conversationMetadata(
                    ConversationMetadataEvent(
                        conversationId: conversationId,
                        agentOutputAudioFormat: agentFormat,
                        userInputAudioFormat: userFormat,
                    ))
            }

        case "ping":
            if let event = json["ping_event"] as? [String: Any],
               let eventId = event["event_id"] as? Int
            {
                let pingMs = event["ping_ms"] as? Int
                return .ping(PingEvent(eventId: eventId, pingMs: pingMs))
            }

        case "client_tool_call":
            if let event = json["client_tool_call"] as? [String: Any],
               let toolName = event["tool_name"] as? String,
               let toolCallId = event["tool_call_id"] as? String,
               let parameters = event["parameters"] as? [String: Any]
            {
                // expects_response is optional, defaulting to true if not specified
                let expectsResponse = event["expects_response"] as? Bool ?? true

                // Convert parameters to JSON data for Sendable compliance
                if let parametersData = try? JSONSerialization.data(withJSONObject: parameters) {
                    return .clientToolCall(
                        ClientToolCallEvent(
                            toolName: toolName,
                            toolCallId: toolCallId,
                            parametersData: parametersData,
                            expectsResponse: expectsResponse,
                        ))
                }
            }

        default:
            return nil
        }

        return nil
    }
}
