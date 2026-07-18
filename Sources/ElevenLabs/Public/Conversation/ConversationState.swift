import Foundation

public enum ConversationState: Equatable, Sendable {
    case idle
    case connecting
    case connected(CallInfo)
    case ended(reason: EndReason)
    case error(ConversationError)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }

    var connectedAgentId: String? {
        if case let .connected(info) = self { return info.agentId }
        return nil
    }
}
