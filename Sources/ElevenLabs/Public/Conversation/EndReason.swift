import Foundation

/// Why a conversation ended. Passed to `onDisconnect` and carried by ``ConversationState/ended(reason:)``.
public enum EndReason: Equatable, Sendable {
    /// The app ended the conversation.
    case userEnded
    /// The agent ended the conversation: it called its `end_call` tool, left the room, or the server
    /// closed the connection normally.
    case agentEnded(Details = Details())
    /// An error ended the conversation: the connection failed, or the server ended it with an error.
    case error(Details = Details())

    /// What the SDK knows about how the remote side ended the conversation; `nil` for ``userEnded``.
    public var details: Details? {
        switch self {
        case .userEnded: nil
        case let .agentEnded(details), let .error(details): details
        }
    }

    /// What the SDK knows about how the remote side ended the conversation.
    public struct Details: Equatable, Sendable {
        /// A description of what ended the conversation, for logs. Not meant to be matched on.
        public var message: String?

        /// The close code the server sent when it closed the WebSocket of a text-only conversation.
        /// `nil` when the connection ended without one, and for voice conversations.
        public var closeCode: Int?

        /// The reason the server sent along with ``closeCode``; `nil` when it sent none.
        public var closeReason: String?

        public init(message: String? = nil, closeCode: Int? = nil, closeReason: String? = nil) {
            self.message = message
            self.closeCode = closeCode
            self.closeReason = closeReason
        }
    }
}
