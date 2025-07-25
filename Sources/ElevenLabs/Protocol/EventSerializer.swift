import Foundation

enum EventSerializer {
    /// Serialize an OutgoingEvent to JSON data
    static func serializeOutgoingEvent(_ event: OutgoingEvent) throws -> Data {
        var json: [String: Any] = [:]

        switch event {
        case let .pong(pongEvent):
            json["type"] = "pong"
            json["event_id"] = pongEvent.eventId

        case let .userAudio(audioEvent):
            json["user_audio_chunk"] = audioEvent.audioChunk

        case let .conversationInit(initEvent):
            json["type"] = "conversation_initiation_client_data"
            if let config = initEvent.config {
                json.merge(buildConversationConfigJSON(config)) { _, new in new }
            }

        case let .feedback(feedbackEvent):
            json["type"] = "feedback"
            json["score"] = feedbackEvent.score.rawValue
            json["event_id"] = feedbackEvent.eventId

        case let .clientToolResult(resultEvent):
            json["type"] = "client_tool_result"
            json["tool_call_id"] = resultEvent.toolCallId
            if let result = try? resultEvent.getResult() {
                json["result"] = result
            }
            json["is_error"] = resultEvent.isError

        case let .contextualUpdate(updateEvent):
            json["type"] = "contextual_update"
            json["text"] = updateEvent.text

        case let .userMessage(messageEvent):
            json["type"] = "user_message"
            json["text"] = messageEvent.text

        case .userActivity:
            json["type"] = "user_activity"

        case let .mcpToolApprovalResult(approvalEvent):
            json["type"] = "mcp_tool_approval_result"
            json["tool_call_id"] = approvalEvent.toolCallId
            json["is_approved"] = approvalEvent.isApproved
        }

        return try JSONSerialization.data(withJSONObject: json)
    }

    private static func buildConversationConfigJSON(_ config: ConversationConfig) -> [String: Any] {
        var json: [String: Any] = [:]
        var configOverride: [String: Any] = [:]

        // Agent overrides
        if let agentOverrides = config.agentOverrides {
            var agent: [String: Any] = [:]
            if let prompt = agentOverrides.prompt {
                agent["prompt"] = ["prompt": prompt]
            }
            if let firstMessage = agentOverrides.firstMessage {
                agent["first_message"] = firstMessage
            }
            if let language = agentOverrides.language {
                agent["language"] = language.rawValue
            }
            if !agent.isEmpty {
                configOverride["agent"] = agent
            }
        }

        // TTS overrides
        if let ttsOverrides = config.ttsOverrides {
            var tts: [String: Any] = [:]
            if let voiceId = ttsOverrides.voiceId {
                tts["voice_id"] = voiceId
            }
            if !tts.isEmpty {
                configOverride["tts"] = tts
            }
        }

        // Conversation overrides
        if let conversationOverrides = config.conversationOverrides {
            var conversation: [String: Any] = [:]
            if conversationOverrides.textOnly {
                conversation["text_only"] = true
            }
            if !conversation.isEmpty {
                configOverride["conversation"] = conversation
            }
        }

        if !configOverride.isEmpty {
            json["conversation_config_override"] = configOverride
        }

        if let customBody = config.customLlmExtraBody {
            json["custom_llm_extra_body"] = customBody
        }

        if let dynamicVars = config.dynamicVariables {
            json["dynamic_variables"] = dynamicVars
        }

        // Add source_info (equivalent to client in React Native)
        var sourceInfo: [String: Any] = [:]
        sourceInfo["source"] = "swift_sdk"
        sourceInfo["version"] = SDKVersion.version
        json["source_info"] = sourceInfo

        // Add user_id if provided
        if let userId = config.userId {
            json["user_id"] = userId
        }

        return json
    }
}
