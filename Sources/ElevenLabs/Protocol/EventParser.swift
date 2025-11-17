import Foundation

enum EventParseError: Error {
    case unknownEventType(String)
    case invalidEventData
}

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
               let transcript = event["user_transcript"] as? String,
               let eventId = event["event_id"] as? Int
            {
                return .userTranscript(UserTranscriptEvent(transcript: transcript, eventId: eventId))
            }

        case "agent_response":
            if let event = json["agent_response_event"] as? [String: Any],
               let response = event["agent_response"] as? String,
               let eventId = event["event_id"] as? Int
            {
                return .agentResponse(AgentResponseEvent(response: response, eventId: eventId))
            }

        case "agent_response_correction":
            if let event = json["agent_response_correction_event"] as? [String: Any],
               let originalResponse = event["original_agent_response"] as? String,
               let correctedResponse = event["corrected_agent_response"] as? String,
               let eventId = event["event_id"] as? Int
            {
                return .agentResponseCorrection(AgentResponseCorrectionEvent(
                    originalAgentResponse: originalResponse,
                    correctedAgentResponse: correctedResponse,
                    eventId: eventId,
                ))
            }

        case "audio":
            if let event = json["audio_event"] as? [String: Any],
               let eventId = event["event_id"] as? Int
            {
                let audioBase64 = (event["audio_base_64"] as? String) ?? ""
                var alignment: AudioAlignment? = nil
                if let alignmentDict = event["alignment"] as? [String: Any],
                   let chars = alignmentDict["chars"] as? [String],
                   let charStartTimesMs = alignmentDict["char_start_times_ms"] as? [Int],
                   let charDurationsMs = alignmentDict["char_durations_ms"] as? [Int]
                {
                    alignment = AudioAlignment(
                        chars: chars,
                        charStartTimesMs: charStartTimesMs,
                        charDurationsMs: charDurationsMs,
                    )
                }

                return .audio(AudioEvent(
                    audioBase64: audioBase64,
                    eventId: eventId,
                    alignment: alignment,
                ))
            }

        case "interruption":
            if let event = json["interruption_event"] as? [String: Any],
               let eventId = event["event_id"] as? Int
            {
                return .interruption(InterruptionEvent(eventId: eventId))
            }

        case "vad_score":
            if let event = json["vad_score_event"] as? [String: Any],
               let vadScore = event["vad_score"] as? Double
            {
                return .vadScore(VadScoreEvent(vadScore: vadScore))
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
               let agentFormat = event["agent_output_audio_format"] as? String,
               let userFormat = event["user_input_audio_format"] as? String
            {
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
               let parameters = event["parameters"] as? [String: Any],
               let eventId = event["event_id"] as? Int
            {
                // Convert parameters to JSON data for Sendable compliance
                if let parametersData = try? JSONSerialization.data(withJSONObject: parameters) {
                    return .clientToolCall(
                        ClientToolCallEvent(
                            toolName: toolName,
                            toolCallId: toolCallId,
                            parametersData: parametersData,
                            eventId: eventId,
                        ))
                }
            }

        case "agent_tool_request":
            if let event = json["agent_tool_request"] as? [String: Any],
               let toolName = event["tool_name"] as? String,
               let toolCallId = event["tool_call_id"] as? String,
               let toolType = event["tool_type"] as? String,
               let eventId = event["event_id"] as? Int
            {
                return .agentToolRequest(
                    AgentToolRequestEvent(
                        toolName: toolName,
                        toolCallId: toolCallId,
                        toolType: toolType,
                        eventId: eventId,
                    ),
                )
            }

        case "agent_tool_response":
            if let event = json["agent_tool_response"] as? [String: Any],
               let toolName = event["tool_name"] as? String,
               let toolCallId = event["tool_call_id"] as? String,
               let toolType = event["tool_type"] as? String,
               let isError = event["is_error"] as? Bool,
               let eventId = event["event_id"] as? Int
            {
                return .agentToolResponse(
                    AgentToolResponseEvent(
                        toolName: toolName,
                        toolCallId: toolCallId,
                        toolType: toolType,
                        isError: isError,
                        eventId: eventId,
                    ))
            }

        case "tentative_user_transcript":
            if let event = json["tentative_user_transcription_event"] as? [String: Any],
               let transcript = event["user_transcript"] as? String,
               let eventId = event["event_id"] as? Int
            {
                return .tentativeUserTranscript(TentativeUserTranscriptEvent(transcript: transcript, eventId: eventId))
            }

        case "mcp_tool_call":
            if let event = json["mcp_tool_call"] as? [String: Any],
               let serviceId = event["service_id"] as? String,
               let toolCallId = event["tool_call_id"] as? String,
               let toolName = event["tool_name"] as? String,
               let parameters = event["parameters"] as? [String: Any],
               let timestamp = event["timestamp"] as? String,
               let state = event["state"] as? String
            {
                if let parametersData = try? JSONSerialization.data(withJSONObject: parameters),
                   let stateEnum = MCPToolCallEvent.State(rawValue: state)
                {
                    let toolDescription = event["tool_description"] as? String
                    let approvalTimeoutSecs = event["approval_timeout_secs"] as? Int
                    let errorMessage = event["error_message"] as? String

                    var resultData: Data? = nil
                    if let result = event["result"] as? [[String: Any]] {
                        resultData = try? JSONSerialization.data(withJSONObject: result)
                    }

                    return .mcpToolCall(MCPToolCallEvent(
                        serviceId: serviceId,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        toolDescription: toolDescription,
                        parametersData: parametersData,
                        timestamp: timestamp,
                        state: stateEnum,
                        approvalTimeoutSecs: approvalTimeoutSecs,
                        resultData: resultData,
                        errorMessage: errorMessage,
                    ))
                }
            }

        case "mcp_connection_status":
            if let event = json["mcp_connection_status"] as? [String: Any],
               let integrationsArray = event["integrations"] as? [[String: Any]]
            {
                let integrations = integrationsArray.compactMap { intData -> MCPConnectionStatusEvent.Integration? in
                    guard let integrationId = intData["integration_id"] as? String,
                          let integrationType = intData["integration_type"] as? String,
                          let isConnected = intData["is_connected"] as? Bool,
                          let toolCount = intData["tool_count"] as? Int
                    else { return nil }

                    return MCPConnectionStatusEvent.Integration(
                        integrationId: integrationId,
                        integrationType: integrationType,
                        isConnected: isConnected,
                        toolCount: toolCount,
                    )
                }

                return .mcpConnectionStatus(MCPConnectionStatusEvent(integrations: integrations))
            }

        case "asr_initiation_metadata":
            if let event = json["asr_initiation_metadata_event"] as? [String: Any],
               let metadataData = try? JSONSerialization.data(withJSONObject: event)
            {
                return .asrInitiationMetadata(ASRInitiationMetadataEvent(metadataData: metadataData))
            }

        case "agent_chat_response_part":
            if let event = json["text_response_part"] as? [String: Any],
               let text = event["text"] as? String
            {
                let partTypeStr = event["type"] as? String ?? "delta"
                let partType = AgentChatResponsePartType(rawValue: partTypeStr) ?? .delta
                return .agentChatResponsePart(AgentChatResponsePartEvent(text: text, type: partType))
            }

        case "error":
            // Skip for now as requested
            break

        default:
            throw EventParseError.unknownEventType(type)
        }

        throw EventParseError.invalidEventData
    }
}
