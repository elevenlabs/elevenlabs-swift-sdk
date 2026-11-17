import Foundation

/// How a conversation ended, delivered to `onDisconnect`.
public struct DisconnectionDetails: Equatable, Sendable {
    /// Why the conversation ended; the same value as `ConversationState.ended(reason:)`.
    public var reason: EndReason

    /// The close code the server sent when it closed the WebSocket of a text-only conversation.
    /// `nil` when the server didn't close the WebSocket, and for voice conversations.
    public var closeCode: Int?

    /// The close reason the server sent along with `closeCode`; `nil` when it sent none.
    public var closeReason: String?

    public init(reason: EndReason, closeCode: Int? = nil, closeReason: String? = nil) {
        self.reason = reason
        self.closeCode = closeCode
        self.closeReason = closeReason
    }
}
