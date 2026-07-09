import Foundation

public enum ConversationState: Equatable, Sendable {
    case idle
    case connecting
    case active(CallInfo)
    case ended(reason: EndReason)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
