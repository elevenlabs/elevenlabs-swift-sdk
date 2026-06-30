import Foundation

public struct ConversationAgentReadyReport: Sendable, Equatable {
    public let elapsed: TimeInterval

    @available(*, deprecated, message: "Ignored: startup now fails if the agent isn't ready (no grace timeout).")
    public let viaGraceTimeout: Bool = false

    @available(*, deprecated, message: "Ignored: startup now fails (throws) if the agent isn't ready.")
    public let timedOut: Bool = false

    public init(elapsed: TimeInterval, viaGraceTimeout _: Bool = false, timedOut _: Bool = false) {
        self.elapsed = elapsed
    }
}
