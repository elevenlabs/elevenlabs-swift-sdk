import Foundation

public struct ConversationStartupConfiguration: Sendable, Equatable {
    public var agentReadyTimeout: TimeInterval

    public init(
        agentReadyTimeout: TimeInterval = 3.0
    ) {
        self.agentReadyTimeout = agentReadyTimeout
    }

    public static let `default` = ConversationStartupConfiguration()
}
