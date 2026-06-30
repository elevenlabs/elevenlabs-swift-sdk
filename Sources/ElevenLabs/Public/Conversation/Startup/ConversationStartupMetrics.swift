import Foundation

public struct ConversationStartupMetrics: Sendable, Equatable {
    public var total: TimeInterval?
    public var tokenFetch: TimeInterval?
    public var roomConnect: TimeInterval?
    public var agentReady: TimeInterval?

    @available(*, deprecated, message: "Ignored: startup now fails if the agent isn't ready (no grace timeout).")
    public var agentReadyViaGraceTimeout: Bool = false

    @available(*, deprecated, message: "Ignored: startup now fails (throws) if the agent isn't ready.")
    public var agentReadyTimedOut: Bool = false

    public var agentReadyBuffer: TimeInterval?
    public var conversationInit: TimeInterval?
    public var conversationInitAttempts: Int

    public init(
        total: TimeInterval? = nil,
        tokenFetch: TimeInterval? = nil,
        roomConnect: TimeInterval? = nil,
        agentReady: TimeInterval? = nil,
        agentReadyViaGraceTimeout _: Bool = false,
        agentReadyTimedOut _: Bool = false,
        agentReadyBuffer: TimeInterval? = nil,
        conversationInit: TimeInterval? = nil,
        conversationInitAttempts: Int = 0
    ) {
        self.total = total
        self.tokenFetch = tokenFetch
        self.roomConnect = roomConnect
        self.agentReady = agentReady
        self.agentReadyBuffer = agentReadyBuffer
        self.conversationInit = conversationInit
        self.conversationInitAttempts = conversationInitAttempts
    }
}
