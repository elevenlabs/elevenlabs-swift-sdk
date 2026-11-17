import Foundation

/// How a conversation ended, delivered to `onDisconnectDetails`.
public struct DisconnectionDetails: Equatable, Sendable {
    /// Why the conversation ended; the same value `onDisconnect` receives.
    public var reason: EndReason

    /// The close code the server sent when it closed the WebSocket of a text-only conversation.
    /// `nil` when the server didn't close the WebSocket, and for voice conversations.
    public var closeCode: Int?

    public init(reason: EndReason, closeCode: Int? = nil) {
        self.reason = reason
        self.closeCode = closeCode
    }
}
