import Foundation

public struct ConversationStartupConfiguration: Sendable, Equatable {
    public var agentReadyTimeout: TimeInterval

    @available(*, deprecated, message: "Ignored: the conversation-init handshake is now sent once (no retries).")
    public var initRetryDelays: [TimeInterval] = [0, 0.2, 0.5]

    @available(*, deprecated, message: "Ignored: startup now always fails if the agent isn't ready in time.")
    public var failIfAgentNotReady: Bool = false

    public init(
        agentReadyTimeout: TimeInterval = 3.0,
        initRetryDelays _: [TimeInterval] = [0, 0.2, 0.5],
        failIfAgentNotReady _: Bool = false
    ) {
        self.agentReadyTimeout = agentReadyTimeout
    }

    public static let `default` = ConversationStartupConfiguration()
}
