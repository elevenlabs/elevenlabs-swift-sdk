import Foundation

public struct Message: Identifiable, Sendable {
    public let id: String
    public let role: Role
    public let content: String
    public let timestamp: Date
    /// Server-assigned event id used for per-message operations like `sendFeedback`; `nil` for locally appended messages.
    public let eventId: Int?
    /// Whether the message is still being assembled and may change. `true` while
    /// an agent message is streaming in from `agent_chat_response_part` chunks,
    /// or while a user message reflects an in-progress (tentative) transcript.
    /// It flips to `false` once the finalized agent response or user transcript
    /// arrives. Locally appended messages are always final (`false`).
    public let isPartial: Bool

    public enum Role: Sendable {
        case user
        case agent
    }

    init(
        id: String,
        role: Role,
        content: String,
        timestamp: Date,
        eventId: Int?,
        isPartial: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.eventId = eventId
        self.isPartial = isPartial
    }
}
