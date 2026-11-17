import Foundation

/// How a conversation ended, delivered to `onDisconnectDetails`.
public struct DisconnectionDetails: Equatable, Sendable {
    /// Why the conversation ended; the same value `onDisconnect` receives.
    public var reason: EndReason

    public init(reason: EndReason) {
        self.reason = reason
    }
}
