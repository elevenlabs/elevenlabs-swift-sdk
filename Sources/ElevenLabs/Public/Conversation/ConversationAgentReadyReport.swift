import Foundation

public struct ConversationAgentReadyReport: Sendable, Equatable {
    public let elapsed: TimeInterval

    public init(elapsed: TimeInterval) {
        self.elapsed = elapsed
    }
}
