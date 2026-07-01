import Foundation

/// The reason a conversation failed to start, carried by
/// ``ConversationState/startupFailed(_:)`` and thrown out of `connect`.
public enum ConversationStartupFailure: Error, Sendable, Equatable {
    case token(ConversationError)
    case room(ConversationError)
    case microphone(ConversationError)
    case agentTimeout
    case conversationInit(ConversationError)

    /// The underlying ``ConversationError`` for this failure, surfaced to
    /// ``ConversationCallbacks/onError`` and rethrown from `connect`.
    public var error: ConversationError {
        switch self {
        case let .token(error),
             let .room(error),
             let .microphone(error),
             let .conversationInit(error):
            return error
        case .agentTimeout:
            return .agentTimeout
        }
    }
}
