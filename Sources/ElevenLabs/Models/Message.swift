import Foundation

/// A message received from the agent.
public struct ReceivedMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let content: Content

    public enum Content: Equatable, Sendable {
        case agentTranscript(String)
        case userTranscript(String)
    }
}

/// A message sent to the agent.
public struct SentMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let content: Content

    public enum Content: Equatable, Sendable {
        case userText(String)
    }
}
