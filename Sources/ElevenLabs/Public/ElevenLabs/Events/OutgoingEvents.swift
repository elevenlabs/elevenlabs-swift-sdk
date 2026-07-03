import Foundation

// MARK: - Outgoing Events (to ElevenLabs)

/// Events that can be sent to the ElevenLabs agent
public enum OutgoingEvent: Sendable {
    case pong(PongEvent)
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
public enum ClientToolErrorType: String, Sendable {
    case userRejected = "user_rejected"
    case externalServer = "external_server"
    case externalClient = "external_client"
    case customerAuth = "customer_auth"
    case unknown
}

public struct ClientToolResultEvent: Sendable {
    public let toolCallId: String
    public let result: String
    public let isError: Bool
    public let errorType: ClientToolErrorType?

    /// `result` is a simple string or a JSON string
    public init(
        toolCallId: String,
        result: String,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) {
        self.toolCallId = toolCallId
        self.result = result
        self.isError = isError || errorType != nil
        self.errorType = errorType
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
