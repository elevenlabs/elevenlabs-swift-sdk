import Foundation
import LiveKit

/// Extracted conversation startup logic
@MainActor
protocol ConversationStartup: Sendable {
    /// Determine optimal buffer time based on agent readiness pattern
    func determineOptimalBuffer(room: Room?) async -> TimeInterval

    /// Wait for the system to be fully ready for conversation initialization
    func waitForSystemReady(room: Room?, timeout: TimeInterval) async -> Bool

    /// Send conversation init with retry logic
    func sendConversationInit(
        config: ConversationConfig,
        publisher: @escaping (OutgoingEvent) async throws -> Void
    ) async throws

    /// Send conversation init with retry logic and track metrics
    func sendConversationInitWithRetry(
        config: ConversationConfig,
        retryDelays: [TimeInterval],
        publisher: @escaping (OutgoingEvent) async throws -> Void,
        onAttempt: (Int) -> Void
    ) async throws -> ConversationInitMetrics
}

/// Metrics from conversation initialization
struct ConversationInitMetrics {
    var attempts: Int = 0
    var duration: TimeInterval = 0
}

/// Default implementation of conversation startup logic
@MainActor
final class DefaultConversationStartup: ConversationStartup {
    private let logger: any Logging

    init(logger: any Logging) {
        self.logger = logger
    }

    func determineOptimalBuffer(room: Room?) async -> TimeInterval {
        guard let room else {
            logger.debug("No room available, using default buffer")
            return 150.0
        }

        guard !room.remoteParticipants.isEmpty else {
            logger.debug("No remote participants found, using longer buffer")
            return 200.0
        }

        let buffer: TimeInterval = 150.0
        logger.debug("Determined optimal buffer: \(Int(buffer))ms")
        return buffer
    }

    func waitForSystemReady(room: Room?, timeout _: TimeInterval) async -> Bool {
        // Event-based approach: readiness is handled in ConnectionManager.waitForAgentReady.
        // This method only performs a quick snapshot (no polling) for API compatibility.
        guard let room else { return false }
        guard room.connectionState == .connected else { return false }
        guard !room.remoteParticipants.isEmpty else { return false }
        return room.remoteParticipants.values.contains { !$0.audioTracks.isEmpty }
    }

    func sendConversationInit(
        config: ConversationConfig,
        publisher: @escaping (OutgoingEvent) async throws -> Void
    ) async throws {
        let initStart = Date()
        let initEvent = ConversationInitEvent(config: config)
        try await publisher(.conversationInit(initEvent))
        let duration = Date().timeIntervalSince(initStart)
        logger.debug("Conversation init sent in \(String(format: "%.3f", duration))s")
    }

    func sendConversationInitWithRetry(
        config: ConversationConfig,
        retryDelays: [TimeInterval],
        publisher: @escaping (OutgoingEvent) async throws -> Void,
        onAttempt: (Int) -> Void
    ) async throws -> ConversationInitMetrics {
        let delays = retryDelays.isEmpty ? [0] : retryDelays
        var metrics = ConversationInitMetrics()

        for (index, delay) in delays.enumerated() {
            let attemptNumber = index + 1
            metrics.attempts = attemptNumber
            onAttempt(attemptNumber)

            if delay > 0 {
                logger.debug("Attempt \(attemptNumber) delay: \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            let attemptStart = Date()
            do {
                try await sendConversationInit(config: config, publisher: publisher)
                metrics.duration = Date().timeIntervalSince(attemptStart)
                logger.info("Conversation init succeeded on attempt \(attemptNumber)")
                return metrics
            } catch {
                metrics.duration = Date().timeIntervalSince(attemptStart)
                logger.warning("Attempt \(attemptNumber) failed: \(error.localizedDescription)")
                if attemptNumber == delays.count {
                    logger.error("All attempts exhausted, conversation init failed")
                    throw error
                }
            }
        }

        throw ConversationError.connectionFailed(NSError(
            domain: "ConversationStartup",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "All retry attempts failed"]
        ))
    }
}
