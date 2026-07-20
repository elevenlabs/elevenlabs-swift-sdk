public struct ConversationStartResult: Equatable, Sendable {
    public let callInfo: CallInfo
    public let metrics: ConversationStartupMetrics
}
