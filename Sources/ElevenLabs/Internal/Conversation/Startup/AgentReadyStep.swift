import Foundation

/// Step responsible for waiting for agent to be ready
final class AgentReadyStep: StartupStep {
    let stepName = "Agent Ready"

    private let connectionManager: any ConnectionManaging
    private let timeout: TimeInterval
    private let failIfNotReady: Bool
    private let logger: any Logging
    private let onResult: (AgentReadyWaitResult) -> Void

    init(
        connectionManager: any ConnectionManaging,
        timeout: TimeInterval,
        failIfNotReady: Bool,
        logger: any Logging,
        onResult: @escaping (AgentReadyWaitResult) -> Void
    ) {
        self.connectionManager = connectionManager
        self.timeout = timeout
        self.failIfNotReady = failIfNotReady
        self.logger = logger
        self.onResult = onResult
    }

    func execute() async throws {
        logger.debug("Waiting for agent ready (timeout: \(timeout)s)...")

        let result = await connectionManager.waitForAgentReady(timeout: timeout)
        onResult(result)

        switch result {
        case let .success(detail):
            let elapsedString = String(format: "%.3f", detail.elapsed)
            logger.info("Agent ready", context: [
                "elapsed": "\(elapsedString)s",
                "viaGraceTimeout": "\(detail.viaGraceTimeout)"
            ])

        case let .timedOut(elapsed):
            logger.warning("Agent timeout after \(String(format: "%.3f", elapsed))s")
            if failIfNotReady {
                throw ConversationError.agentTimeout
            }
        }
    }
}
