import Foundation

public enum ConversationStartupFailure: Sendable, Equatable {
    case token(ConversationError)
    case room(ConversationError)
    case agentTimeout
    case conversationInit(ConversationError)
}
