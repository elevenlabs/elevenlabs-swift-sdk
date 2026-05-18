import Foundation

/// Step responsible for waiting for agent to be ready.
///
/// Races the connection manager's "track subscribed" signal against `timeout`.
/// On timeout, throws if `failIfNotReady`; otherwise promotes the result to
/// `.success(viaGraceTimeout: true)` so the startup proceeds optimistically.
final class AgentReadyStep: StartupStep {
    let stepName = "Agent Ready"

    private let webRTCConnectionManager: any WebRTCConnectionManaging
    private let timeout: TimeInterval
    private let failIfNotReady: Bool
    private let logger: any Logging
    private let onResult: (AgentReadyWaitResult) -> Void

    init(
        webRTCConnectionManager: any WebRTCConnectionManaging,
        timeout: TimeInterval,
        failIfNotReady: Bool,
        logger: any Logging,
        onResult: @escaping (AgentReadyWaitResult) -> Void
    ) {
        self.webRTCConnectionManager = webRTCConnectionManager
        self.timeout = timeout
        self.failIfNotReady = failIfNotReady
        self.logger = logger
        self.onResult = onResult
    }

    func execute() async throws {
        logger.debug("Waiting for agent ready (timeout: \(timeout)s)...")

        let raw = await webRTCConnectionManager.waitForAgentReady(timeout: timeout)

        switch raw {
        case let .success(detail):
            onResult(.success(detail))
            logger.info("Agent ready", context: [
                "elapsed": "\(String(format: "%.3f", detail.elapsed))s",
                "viaGraceTimeout": "\(detail.viaGraceTimeout)"
            ])

        case let .timedOut(elapsed):
            if failIfNotReady {
                onResult(.timedOut(elapsed: elapsed))
                logger.warning("Agent timeout after \(String(format: "%.3f", elapsed))s")
                throw ConversationError.agentTimeout
            }
            let promoted = AgentReadyDetail(elapsed: elapsed, viaGraceTimeout: true)
            onResult(.success(promoted))
            logger.warning("Agent readiness grace timeout reached after \(String(format: "%.3f", elapsed))s; proceeding anyway")
        }
    }
}
