import Foundation

public protocol ChatHistoryItem: Identifiable, Sendable where ID == String {}

extension ChatHistoryItem {
    public var message: Message? {
        self as? Message
    }

    public var toolCall: ConversationToolCall? {
        self as? ConversationToolCall
    }
}

public struct Message: ChatHistoryItem {
    public enum Role: Sendable, Equatable {
        case user
        case agent
    }

    /// Agent messages use the server `responseId`. User messages are session-local.
    public let id: String
    public let role: Role
    public internal(set) var content: String
    public let timestamp: Date
    public internal(set) var isFinal: Bool
    /// Turn-scoped server event ID used for operations such as feedback.
    public internal(set) var eventId: Int?

    init(
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isFinal: Bool,
        eventId: Int? = nil,
        responseId: String? = nil
    ) {
        id = responseId ?? UUID().uuidString
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isFinal = isFinal
        self.eventId = eventId
    }
}

public struct ConversationToolCall: ChatHistoryItem {
    public var id: String {
        "tool_call:\(toolCallId)"
    }

    public let toolCallId: String
    public let toolName: String
}
