import AVFoundation
import Foundation
import LiveKit

// swiftlint:disable function_body_length cyclomatic_complexity

/// Orchestrates the conversation startup sequence using individual steps
@MainActor
final class ConversationStartupOrchestrator {
    private let logger: any Logging

    init(logger: any Logging) {
        self.logger = logger
    }

    /// Execute the full startup sequence
    func execute(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        provider: any ConversationDependencyProvider,
        onStateChange: @escaping (ConversationStartupState) -> Void,
        onRoomConnected: @escaping (Room) -> Void
    ) async throws -> StartupResult {
        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        // Cache connection manager for synchronous access throughout startup
        let connectionManager = await provider.connectionManager()

        let agentId = extractAgentId(from: auth)
        let context = ["agentId": agentId]
        logger.info("Starting conversation startup sequence", context: context)

        // Step 1: Parallel Token Resolution & Mic Permission
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

        // Step 1: Token Fetch & Permission Request in parallel
        let tokenStart = Date()

        // Run both operations in parallel using async let.
        // Note: async let is preferred over TaskGroup for exactly 2 parallel operations
        // as it's more concise and equally performant. TaskGroup would be better for
        // dynamic number of tasks or when collecting results iteratively.
        async let tokenResult: Void = tokenStep.execute()
        async let permissionResult: Bool = {
            guard !options.conversationOverrides.textOnly else { return true }
            return await withCheckedContinuation { continuation in
                #if os(iOS)
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
                #elseif os(macOS)
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    continuation.resume(returning: true)
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                case .denied, .restricted:
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: false)
                }
                #endif
            }
        }()

        let permissionGranted: Bool
        do {
            try await tokenResult
            permissionGranted = await permissionResult
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

        // Step 2: Room Connection
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

        // Step 3: Agent Ready
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

        // Step 3b: Process Agent Ready Result (Non-failing or Success)
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

        // Step 4: Conversation Init
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
}

// swiftlint:enable function_body_length cyclomatic_complexity

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
