import Foundation

public struct Message: Identifiable, Sendable {
    public let id: String
    public let role: Role
    /// Exact message content received from or sent to the conversation.
    public let content: String
    /// Human-readable conversation transcript.
    /// Audio tags are removed from agent messages in voice conversations.
    public let transcript: String
    public let timestamp: Date
    /// Server-assigned event id used for per-message operations like `sendFeedback`.
    /// This is `nil` for locally appended messages.
    public let eventId: Int?

    public enum Role: Sendable {
        case user
        case agent
    }
}
