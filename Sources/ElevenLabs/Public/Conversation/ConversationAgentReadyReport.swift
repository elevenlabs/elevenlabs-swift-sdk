import Foundation

public struct ConversationAgentReadyReport: Sendable, Equatable {
    public let elapsed: TimeInterval
    public let viaGraceTimeout: Bool
    public let timedOut: Bool

    public init(elapsed: TimeInterval, viaGraceTimeout: Bool, timedOut: Bool) {
        self.elapsed = elapsed
        self.viaGraceTimeout = viaGraceTimeout
        self.timedOut = timedOut
    }
}
