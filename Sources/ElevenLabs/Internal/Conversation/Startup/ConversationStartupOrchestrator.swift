import AVFoundation
import Foundation
import LiveKit

/// Orchestrates the conversation startup sequence using individual steps
@MainActor
final class ConversationStartupOrchestrator {
    private let logger: any Logging

    init(logger: any Logging) {
        self.logger = logger
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    /// Execute the full startup sequence: resolve token, request microphone permission (if needed), connect room,
    // wait for agent readiness, send conversation init (with retries), and return startup metrics.
    func execute(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        provider: any ConversationDependencyProvider,
        onStateChange: @escaping (ConversationStartupState) -> Void,
        onRoomConnected: @escaping (Room) -> Void
    ) async throws -> StartupResult {
        let connectionManager = await provider.connectionManager()
        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        let agentId = extractAgentId(from: auth)
        let context = ["agentId": agentId]
        logger.info("Starting conversation startup sequence", context: context)

        onStateChange(.resolvingToken)

        var connectionDetails: TokenService.ConnectionDetails?
        let tokenService = await provider.tokenService
        let tokenStep = TokenResolutionStep(
            tokenService: tokenService,
            auth: auth,
            logger: logger
        ) { details in
            connectionDetails = details
        }

        let tokenStart = Date()
        do {
            try await tokenStep.execute()
            metrics.tokenFetch = Date().timeIntervalSince(tokenStart)
        } catch is CancellationError {
            // Handle cancellation separately - don't wrap in StartupFailure
            metrics.tokenFetch = Date().timeIntervalSince(tokenStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw CancellationError()
        } catch {
            metrics.tokenFetch = Date().timeIntervalSince(tokenStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw StartupFailure.token(error as? ConversationError ?? .connectionFailed(error), metrics)
        }

        let permissionGranted = await requestMicrophonePermissionIfNeeded(textOnly: options.conversationOverrides.textOnly)

        onStateChange(.connectingRoom)
        let throwOnMicFailure = options.microphoneFailureHandling == .throwError
        guard let safeDetails = connectionDetails else {
            metrics.total = Date().timeIntervalSince(startTime)
            throw StartupFailure.token(.authenticationFailed("Missing connection details"), metrics)
        }

        let roomStep = RoomConnectionStep(
            connectionManager: connectionManager,
            details: safeDetails,
            enableMic: !options.conversationOverrides.textOnly && permissionGranted,
            throwOnMicrophoneFailure: throwOnMicFailure,
            networkConfiguration: options.networkConfiguration,
            graceTimeout: options.startupConfiguration.agentReadyTimeout,
            logger: logger
        )

        let roomStart = Date()
        do {
            try await roomStep.execute()
            metrics.roomConnect = Date().timeIntervalSince(roomStart)

            if let room = connectionManager.room {
                onRoomConnected(room)
            }
        } catch is CancellationError {
            // Handle cancellation separately - don't wrap in StartupFailure
            metrics.roomConnect = Date().timeIntervalSince(roomStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw CancellationError()
        } catch {
            metrics.roomConnect = Date().timeIntervalSince(roomStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw StartupFailure.room(error as? ConversationError ?? .connectionFailed(error), metrics)
        }

        onStateChange(
            .waitingForAgent(
                timeout: options.startupConfiguration.agentReadyTimeout
            )
        )
        var agentResult: AgentReadyWaitResult?
        let agentStep = AgentReadyStep(
            connectionManager: connectionManager,
            timeout: options.startupConfiguration.agentReadyTimeout,
            failIfNotReady: options.startupConfiguration.failIfAgentNotReady,
            logger: logger
        ) { result in
            agentResult = result
        }

        let agentStart = Date()
        do {
            try await agentStep.execute()
        } catch {
            // Apply captured agentResult details if available
            if case let .timedOut(elapsed) = agentResult {
                metrics.agentReady = elapsed
                metrics.agentReadyTimedOut = true
            } else {
                metrics.agentReady = Date().timeIntervalSince(agentStart)
            }
            metrics.total = Date().timeIntervalSince(startTime)
            throw StartupFailure.agentTimeout(metrics)
        }

        if let result = agentResult {
            switch result {
            case let .success(detail):
                metrics.agentReady = detail.elapsed
                metrics.agentReadyViaGraceTimeout = detail.viaGraceTimeout

                let report = ConversationAgentReadyReport(
                    elapsed: detail.elapsed,
                    viaGraceTimeout: detail.viaGraceTimeout,
                    timedOut: false
                )
                onStateChange(.agentReady(report))

            case let .timedOut(elapsed):
                metrics.agentReady = elapsed
                metrics.agentReadyTimedOut = true

                let report = ConversationAgentReadyReport(
                    elapsed: elapsed,
                    viaGraceTimeout: false,
                    timedOut: true
                )
                onStateChange(.agentReady(report))
            }
        } else {
            // Fallback for safety
            metrics.agentReady = Date().timeIntervalSince(agentStart)
        }

        let initStep = ConversationInitStep(
            connectionManager: connectionManager,
            config: options.toConversationConfig(),
            retryDelays: options.startupConfiguration.initRetryDelays,
            logger: logger
        ) { attemptNumber in
            onStateChange(.sendingConversationInit(attempt: attemptNumber))
        }

        let initStart = Date()
        do {
            try await initStep.execute()
            metrics.conversationInit = Date().timeIntervalSince(initStart)
            metrics.conversationInitAttempts = initStep.attemptsMade
        } catch {
            metrics.conversationInit = Date().timeIntervalSince(initStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw StartupFailure.conversationInit(error as? ConversationError ?? .connectionFailed(error), metrics)
        }

        metrics.total = Date().timeIntervalSince(startTime)

        return StartupResult(
            agentId: extractAgentId(from: auth),
            metrics: metrics
        )
    }

    private func extractAgentId(from auth: ElevenLabsConfiguration) -> String {
        switch auth.authSource {
        case let .publicAgentId(id):
            id
        case .conversationToken, .customTokenProvider:
            "unknown"
        }
    }

    private func requestMicrophonePermissionIfNeeded(textOnly: Bool) async -> Bool {
        guard !textOnly else { return true }
        #if os(iOS)
        return await AVAudioSession.sharedInstance().requestRecordPermission()
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #endif
    }
}

// MARK: - Result Types

struct StartupResult {
    let agentId: String
    let metrics: ConversationStartupMetrics
}

enum StartupFailure: Error {
    case token(ConversationError, ConversationStartupMetrics)
    case room(ConversationError, ConversationStartupMetrics)
    case agentTimeout(ConversationStartupMetrics)
    case conversationInit(ConversationError, ConversationStartupMetrics)
}
