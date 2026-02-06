import Foundation

public enum ConversationStartupState: Sendable, Equatable {
    case idle
    case resolvingToken
    case connectingRoom
    case waitingForAgent(timeout: TimeInterval)
    case agentReady(ConversationAgentReadyReport)
    case sendingConversationInit(attempt: Int)
    case active(CallInfo, ConversationStartupMetrics)
    case failed(ConversationStartupFailure, ConversationStartupMetrics)
}
