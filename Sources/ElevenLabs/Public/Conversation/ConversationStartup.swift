import Foundation

/// In-flight startup stage while `ConversationState` is `.connecting`.
public enum ConversationStartupState: Sendable, Equatable {
    /// Session teardown / wiring before transport-specific stages begin.
    case preparing
    case resolvingToken
    case connectingRoom
    case waitingForAgent(timeout: TimeInterval)
    case agentReady(elapsed: TimeInterval)
    case sendingConversationInit
    case waitingForInitiationMetadata(timeout: TimeInterval)
}

public struct ConversationStartupMetrics: Sendable, Equatable {
    public var total: TimeInterval?
    public var tokenFetch: TimeInterval?
    public var roomConnect: TimeInterval?
    public var agentReady: TimeInterval?

    public var agentReadyBuffer: TimeInterval?
    public var conversationInit: TimeInterval?
    public var initiationMetadata: TimeInterval?

    public init(
        total: TimeInterval? = nil,
        tokenFetch: TimeInterval? = nil,
        roomConnect: TimeInterval? = nil,
        agentReady: TimeInterval? = nil,
        agentReadyViaGraceTimeout _: Bool = false,
        agentReadyTimedOut _: Bool = false,
        agentReadyBuffer: TimeInterval? = nil,
        conversationInit: TimeInterval? = nil,
        initiationMetadata: TimeInterval? = nil
    ) {
        self.total = total
        self.tokenFetch = tokenFetch
        self.roomConnect = roomConnect
        self.agentReady = agentReady
        self.agentReadyBuffer = agentReadyBuffer
        self.conversationInit = conversationInit
        self.initiationMetadata = initiationMetadata
    }
}

public struct ConversationStartResult: Equatable, Sendable {
    public let callInfo: CallInfo
    public let metrics: ConversationStartupMetrics
}
