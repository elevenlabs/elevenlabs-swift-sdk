import Foundation

/// Tracks timing metrics for the conversation bootstrap sequence.
/// Encapsulating this logic keeps `Conversation.startConversation` focused on control flow
/// and simplifies future tweaks to the telemetry we collect.
struct ConversationStartupTracker {
    typealias Now = @Sendable () -> Date

    private let now: Now
    private let startTime: Date
    private var tokenFetchStart: Date?
    private var roomConnectStart: Date?
    private var conversationInitStart: Date?

    private(set) var metrics = ConversationStartupMetrics()

    init(now: @escaping Now = { Date() }) {
        self.now = now
        startTime = now()
    }

    mutating func markTokenFetchStarted() {
        tokenFetchStart = now()
    }

    mutating func markTokenFetchCompleted() {
        metrics.tokenFetch = elapsed(since: tokenFetchStart)
    }

    mutating func markRoomConnectStarted() {
        roomConnectStart = now()
    }

    mutating func markRoomConnectCompleted() {
        metrics.roomConnect = elapsed(since: roomConnectStart)
    }

    mutating func markAgentReadySuccess(detail: AgentReadyDetail) {
        metrics.agentReady = detail.elapsed
        metrics.agentReadyViaGraceTimeout = detail.viaGraceTimeout
        metrics.agentReadyTimedOut = false
    }

    mutating func markAgentReadyTimeout(elapsed: TimeInterval) {
        metrics.agentReady = elapsed
        metrics.agentReadyTimedOut = true
    }

    mutating func recordAgentReadyBuffer(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        metrics.agentReadyBuffer = seconds
    }

    mutating func recordConversationInitAttempt(_ attempt: Int) {
        metrics.conversationInitAttempts = attempt
    }

    mutating func markConversationInitStarted() {
        conversationInitStart = now()
    }

    mutating func markConversationInitFinished() {
        metrics.conversationInit = elapsed(since: conversationInitStart)
    }

    mutating func finalizeTotal() {
        metrics.total = now().timeIntervalSince(startTime)
    }

    private func elapsed(since date: Date?) -> TimeInterval? {
        guard let date else { return nil }
        return now().timeIntervalSince(date)
    }
}
