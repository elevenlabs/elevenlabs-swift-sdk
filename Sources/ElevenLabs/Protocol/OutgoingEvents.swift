import Foundation

// MARK: - Outgoing Events (to ElevenLabs)

/// Events that can be sent to the ElevenLabs agent
public enum OutgoingEvent {
    case pong(PongEvent)
    case userAudio(UserAudioEvent)
    case conversationInit(ConversationInitEvent)
    case feedback(FeedbackEvent)
    case clientToolResult(ClientToolResultEvent)
    case contextualUpdate(ContextualUpdateEvent)
    case userMessage(UserMessageEvent)
    case userActivity
    case mcpToolApprovalResult(MCPToolApprovalResultEvent)
}

/// Pong response to ping
public struct PongEvent: Sendable {
    public let eventId: Int

    public init(eventId: Int) {
        self.eventId = eventId
    }
}

/// User audio chunk
public struct UserAudioEvent: Sendable {
    public let audioChunk: String // base64 encoded

    public init(audioChunk: String) {
        self.audioChunk = audioChunk
    }
}

/// Conversation initialization
public struct ConversationInitEvent: Sendable {
    public let config: ConversationConfig?

    public init(config: ConversationConfig? = nil) {
        self.config = config
    }
}

/// User feedback
public struct FeedbackEvent: Sendable {
    public enum Score: String, Sendable {
        case like
        case dislike
    }

    public let score: Score
    public let eventId: Int

    public init(score: Score, eventId: Int) {
        self.score = score
        self.eventId = eventId
    }
}

/// Client tool execution result
public struct ClientToolResultEvent: Sendable {
    public let toolCallId: String
    public let result: String
    public let isError: Bool

    public init(toolCallId: String, result: Any, isError: Bool = false) throws {
        self.toolCallId = toolCallId
        self.isError = isError

        if let stringResult = result as? String {
            self.result = stringResult
        } else if JSONSerialization.isValidJSONObject(result) {
            let jsonData = try JSONSerialization.data(withJSONObject: result)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw NSError(domain: "ClientToolResultEvent", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "Failed to convert result to JSON string"])
            }
            self.result = jsonString
        } else {
            self.result = String(describing: result)
        }
    }

    public init(toolCallId: String, result: String, isError: Bool = false) {
        self.toolCallId = toolCallId
        self.result = result
        self.isError = isError
    }
}

/// Contextual update to the conversation
public struct ContextualUpdateEvent: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// User text message
public struct UserMessageEvent: Sendable {
    public let text: String?

    public init(text: String?) {
        self.text = text
    }
}

/// MCP tool approval result
public struct MCPToolApprovalResultEvent: Sendable {
    public let toolCallId: String
    public let isApproved: Bool

    public init(toolCallId: String, isApproved: Bool) {
        self.toolCallId = toolCallId
        self.isApproved = isApproved
    }
}
