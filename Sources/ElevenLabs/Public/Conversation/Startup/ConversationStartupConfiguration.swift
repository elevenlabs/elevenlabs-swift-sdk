import Foundation

public struct ConversationStartupConfiguration: Sendable, Equatable {
    public var agentReadyTimeout: TimeInterval
    public var initiationMetadataTimeout: TimeInterval

    public init(
        agentReadyTimeout: TimeInterval = 3.0,
        initiationMetadataTimeout: TimeInterval = 5.0
    ) {
        self.agentReadyTimeout = agentReadyTimeout
        self.initiationMetadataTimeout = initiationMetadataTimeout
    }

    public static let `default` = ConversationStartupConfiguration()
}
