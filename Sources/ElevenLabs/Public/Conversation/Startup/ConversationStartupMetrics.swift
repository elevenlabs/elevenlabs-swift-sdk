import Foundation

public struct ConversationStartupMetrics: Sendable, Equatable {
    public var total: TimeInterval?
    public var tokenFetch: TimeInterval?
    public var roomConnect: TimeInterval?
    public var agentReady: TimeInterval?
    public var agentReadyViaGraceTimeout: Bool
    public var agentReadyTimedOut: Bool
    public var agentReadyBuffer: TimeInterval?
    public var conversationInit: TimeInterval?
    public var conversationInitAttempts: Int

    public init(
        total: TimeInterval? = nil,
        tokenFetch: TimeInterval? = nil,
        roomConnect: TimeInterval? = nil,
        agentReady: TimeInterval? = nil,
        agentReadyViaGraceTimeout: Bool = false,
        agentReadyTimedOut: Bool = false,
        agentReadyBuffer: TimeInterval? = nil,
        conversationInit: TimeInterval? = nil,
        conversationInitAttempts: Int = 0
    ) {
        self.total = total
        self.tokenFetch = tokenFetch
        self.roomConnect = roomConnect
        self.agentReady = agentReady
        self.agentReadyViaGraceTimeout = agentReadyViaGraceTimeout
        self.agentReadyTimedOut = agentReadyTimedOut
        self.agentReadyBuffer = agentReadyBuffer
        self.conversationInit = conversationInit
        self.conversationInitAttempts = conversationInitAttempts
    }
}
