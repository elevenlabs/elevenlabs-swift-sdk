import Foundation

public enum ConversationState: Equatable, Sendable {
    case idle
    case connecting(ConversationStartupState)
    case connected(CallInfo)
    case ended(reason: EndReason)
    case error(ConversationError)

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var connectedAgentId: String? {
        if case let .connected(info) = self { return info.agentId }
        return nil
    }
}

public struct CallInfo: Equatable, Sendable {
    public let agentId: String
    public let conversationId: String
}

public enum EndReason: Equatable, Sendable {
    case userEnded
    case remoteDisconnected
}
