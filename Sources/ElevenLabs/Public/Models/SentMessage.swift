import Foundation

/// A message sent to the agent.
@available(*, deprecated, message: "No longer used by the SDK. Observe `Conversation.messages` instead. Will be removed in 4.0.")
public struct SentMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let content: Content

    public enum Content: Equatable, Sendable {
        case userText(String)
    }
}
