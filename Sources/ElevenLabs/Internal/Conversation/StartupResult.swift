import Foundation

struct StartupResult {
    let agentId: String
    let metrics: ConversationStartupMetrics
}

struct StartupFailure: Error {
    let reason: ConversationStartupFailure
    let error: ConversationError
    let metrics: ConversationStartupMetrics

    static func token(_ error: ConversationError, _ metrics: ConversationStartupMetrics) -> Self {
        .init(reason: .token(error), error: error, metrics: metrics)
    }

    static func room(_ error: ConversationError, _ metrics: ConversationStartupMetrics) -> Self {
        .init(reason: .room(error), error: error, metrics: metrics)
    }

    static func agentTimeout(_ metrics: ConversationStartupMetrics) -> Self {
        .init(reason: .agentTimeout, error: .agentTimeout, metrics: metrics)
    }

    static func conversationInit(_ error: ConversationError, _ metrics: ConversationStartupMetrics) -> Self {
        .init(reason: .conversationInit(error), error: error, metrics: metrics)
    }
}
