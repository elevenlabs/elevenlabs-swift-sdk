import Foundation

// MARK: - Outgoing Events (to ElevenLabs)

/// Events that can be sent to the ElevenLabs agent
enum OutgoingEvent {
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
struct PongEvent: Sendable {
    let eventId: Int
}

/// User audio chunk
struct UserAudioEvent: Sendable {
    let audioChunk: String // base64 encoded
}

/// Conversation initialization
struct ConversationInitEvent: Sendable {
    let config: ConversationConfig?

    init(config: ConversationConfig? = nil) {
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

/// Categorizes a client tool failure for the orchestrator.
public enum ClientToolErrorType: String, Sendable {
    case userRejected = "user_rejected"
    case externalServer = "external_server"
    case externalClient = "external_client"
    case customerAuth = "customer_auth"
    case clientTimeout = "client_timeout"
    case unknown
}

/// Client tool execution result
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

    /// JSON-encodes `result` before creating the event.
    public init(
        toolCallId: String,
        result: some Encodable,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) throws {
        let json = try String(decoding: JSONEncoder().encode(result), as: UTF8.self)
        self.init(
            toolCallId: toolCallId,
            result: json,
            isError: isError,
            errorType: errorType
        )
    }
}

/// Contextual update to the conversation
struct ContextualUpdateEvent: Sendable {
    let text: String
}

/// User text message
struct UserMessageEvent: Sendable {
    let text: String?
}

/// MCP tool approval result
struct MCPToolApprovalResultEvent: Sendable {
    let toolCallId: String
    let isApproved: Bool
}
