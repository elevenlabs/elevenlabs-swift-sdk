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
    public let resultData: Data // Store as JSON data to be Sendable
    public let isError: Bool

    public init(toolCallId: String, result: Any, isError: Bool = false) throws {
        self.toolCallId = toolCallId
        // Handle different result types appropriately for JSON serialization
        if JSONSerialization.isValidJSONObject(result) {
            resultData = try JSONSerialization.data(withJSONObject: result)
        } else {
            // For strings, numbers, bools, wrap in an array to make valid JSON
            resultData = try JSONSerialization.data(withJSONObject: [result])
        }
        self.isError = isError
    }

    /// Get result as Any (not Sendable, use carefully)
    public func getResult() throws -> Any {
        let jsonObject = try JSONSerialization.jsonObject(with: resultData)
        // If we wrapped a single value in an array, unwrap it
        if let array = jsonObject as? [Any], array.count == 1 {
            return array[0]
        }
        return jsonObject
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
