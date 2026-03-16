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
    /// Optional environment for the agent (defaults to production when nil)
    public let environment: String?

    /// Initialize with a public agent ID
    public static func publicAgent(id: String, participantName: String = "user", environment: String? = nil) -> Self {
        .init(authSource: .publicAgentId(id), participantName: participantName, environment: environment)
    }

    /// Initialize with a conversation token
    public static func conversationToken(_ token: String, participantName: String = "user", environment: String? = nil) -> Self {
        .init(authSource: .conversationToken(token), participantName: participantName, environment: environment)
    }

    /// Initialize with a custom token provider
    public static func customTokenProvider(
        _ provider: @escaping @Sendable () async throws -> String,
        participantName: String = "user",
        environment: String? = nil
    ) -> Self {
        .init(authSource: .customTokenProvider(provider), participantName: participantName, environment: environment)
    }
}
