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
