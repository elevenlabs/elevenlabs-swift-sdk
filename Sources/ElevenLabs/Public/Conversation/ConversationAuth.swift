import Foundation

/// Grants for starting a conversation. Voice and text take different ones —
/// pass them to ``ConversationClient/startVoiceConversation(_:config:)`` or
/// ``ConversationClient/startTextOnlyConversation(_:config:)``.
public enum ConversationAuth {
    public enum Voice: Sendable {
        case publicAgent(id: String)
        /// Called once per start. Use ``conversationToken(_:)`` for a pre-fetched token.
        case conversationToken(@Sendable () async throws -> String)

        public var agentId: String {
            switch self {
            case let .publicAgent(id): id
            case .conversationToken: "unknown"
            }
        }

        public static func conversationToken(_ token: String) -> Self {
            .conversationToken { token }
        }
    }

    public enum TextOnly: Sendable {
        case publicAgent(id: String)
        case signedWebSocketURL(mint: @Sendable () async throws -> String)

        public static func signedWebSocketURL(_ url: String) -> Self {
            .signedWebSocketURL(mint: { url })
        }

        public var agentId: String {
            switch self {
            case let .publicAgent(id): id
            case .signedWebSocketURL: "unknown"
            }
        }
    }
}
