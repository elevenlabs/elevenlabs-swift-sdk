import Foundation

public struct ConversationStartupConfiguration: Sendable, Equatable {
    public var agentReadyTimeout: TimeInterval
    public var initRetryDelays: [TimeInterval]
    public var failIfAgentNotReady: Bool

    public init(
        agentReadyTimeout: TimeInterval = 3.0,
        initRetryDelays: [TimeInterval] = [0, 0.2, 0.5],
        failIfAgentNotReady: Bool = false
    ) {
        self.agentReadyTimeout = agentReadyTimeout
        self.initRetryDelays = initRetryDelays
        self.failIfAgentNotReady = failIfAgentNotReady
    }

    public static let `default` = ConversationStartupConfiguration()
}
