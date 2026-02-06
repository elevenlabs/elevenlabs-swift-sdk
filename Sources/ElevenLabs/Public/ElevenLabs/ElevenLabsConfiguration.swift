import Foundation

/// Configuration for ElevenLabs conversational AI
public struct ElevenLabsConfiguration: Sendable {
    /// The source of authentication for the conversation
    public enum AuthSource: Sendable {
        /// Use a public agent ID (no authentication required)
        case publicAgentId(String)
        /// Use a conversation token from your backend
        case conversationToken(String)
        /// Custom token provider for advanced use cases
        case customTokenProvider(@Sendable () async throws -> String)
    }

    public let authSource: AuthSource
    public let participantName: String

    /// Initialize with a public agent ID
    public static func publicAgent(id: String, participantName: String = "user") -> Self {
        .init(authSource: .publicAgentId(id), participantName: participantName)
    }

    /// Initialize with a conversation token
    public static func conversationToken(_ token: String, participantName: String = "user") -> Self {
        .init(authSource: .conversationToken(token), participantName: participantName)
    }

    /// Initialize with a custom token provider
    public static func customTokenProvider(
        _ provider: @escaping @Sendable () async throws -> String,
        participantName: String = "user"
    ) -> Self {
        .init(authSource: .customTokenProvider(provider), participantName: participantName)
    }
}
