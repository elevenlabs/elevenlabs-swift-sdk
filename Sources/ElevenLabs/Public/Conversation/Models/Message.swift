import Foundation

public struct Message: Identifiable, Sendable {
    public let id: String
    public let role: Role
    public let content: String
    public let timestamp: Date
    /// Server-assigned event id used for per-message operations like `sendFeedback`; `nil` for locally appended messages.
    public let eventId: Int?
    let responseId: String?
    let isFinal: Bool

    public enum Role: Sendable {
        case user
        case agent
    }

    func updating(content: String, isFinal: Bool) -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            eventId: eventId,
            responseId: responseId,
            isFinal: isFinal
        )
    }
}
