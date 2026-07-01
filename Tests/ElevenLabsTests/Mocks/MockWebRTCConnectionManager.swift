@testable import ElevenLabs
import Foundation
import LiveKit

final class MockWebRTCConnectionManager: WebRTCConnectionManaging {
    enum Error: Swift.Error {
        case connectionFailed
        case publishFailed
    }

    var onDisconnected: (() async -> Void)?
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?

    var room: Room?

    var inputTrack: LocalAudioTrack?
    var agentAudioTrack: RemoteAudioTrack?
    var isMicrophoneMuted = true

    var errorHandler: ((Swift.Error?) -> Void)?

    var shouldFailConnection = false
    var connectionError: Swift.Error = Error.connectionFailed
    var tokenError: ConversationError?
    var publishError: Swift.Error?
    var microphoneError: Swift.Error?

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastNetworkConfiguration: LiveKitNetworkConfiguration = .default
    private(set) var lastWaitTimeout: TimeInterval = 0
    private(set) var publishedPayloads: [Data] = []

    private var waitContinuation: CheckedContinuation<AgentReadyWaitResult, Never>?
    private var pendingWaitResult: AgentReadyWaitResult?

    /// Simulates the full WebRTC startup (token → room → agent → init), driven by
    /// the `tokenError`/`shouldFailConnection`/`publishError` flags and the
    /// agent-ready continuation (`succeedAgentReady`/`timeoutAgentReady`).
    @MainActor
    func connect(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> StartupResult {
        connectCallCount += 1
        lastNetworkConfiguration = options.networkConfiguration
        var metrics = ConversationStartupMetrics()

        onStartupStateChange(.resolvingToken)
        if let tokenError {
            throw StartupFailure.token(tokenError, metrics)
        }

        onStartupStateChange(.connectingRoom)
        if shouldFailConnection {
            errorHandler?(connectionError)
            throw StartupFailure.room(connectionError as? ConversationError ?? .connectionFailed(connectionError), metrics)
        }
        room = Room()

        onStartupStateChange(.waitingForAgent(timeout: options.startupConfiguration.agentReadyTimeout))
        switch await waitForAgentReady(timeout: options.startupConfiguration.agentReadyTimeout) {
        case let .success(elapsed):
            metrics.agentReady = elapsed
            onStartupStateChange(.agentReady(ConversationAgentReadyReport(elapsed: elapsed)))
        case let .timedOut(elapsed):
            metrics.agentReady = elapsed
            throw StartupFailure.agentTimeout(metrics)
        }

        onStartupStateChange(.sendingConversationInit(attempt: 1))
        do {
            try await send(event: .conversationInit(ConversationInitEvent(config: options.toConversationConfig())))
        } catch {
            throw StartupFailure.conversationInit(error as? ConversationError ?? .connectionFailed(error), metrics)
        }
        metrics.conversationInitAttempts = 1

        return StartupResult(agentId: auth.agentId, metrics: metrics)
    }

    func disconnect() async {
        disconnectCallCount += 1
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil
        onRemoteSpeakingChanged = nil
        room = nil
    }

    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult {
        lastWaitTimeout = timeout
        if let pending = pendingWaitResult {
            pendingWaitResult = nil
            return pending
        }

        return await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func send(data: Data) async throws {
        guard room != nil else {
            throw ConnectionManagerError.notConnected
        }
        if let publishError {
            errorHandler?(publishError)
            throw publishError
        }
        publishedPayloads.append(data)
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard room != nil else {
            throw WebRTCConnectionManagerError.roomUnavailable
        }
        if let microphoneError {
            errorHandler?(microphoneError)
            throw microphoneError
        }
        isMicrophoneMuted = muted
    }

    // MARK: - Helpers

    func receive(data: Data) {
        handleIncomingData(data, logger: SDKLogger(logLevel: .error))
    }

    func succeedAgentReady(elapsed: TimeInterval = 0.1) {
        resumeWait(with: .success(elapsed: elapsed))
    }

    func timeoutAgentReady(elapsed: TimeInterval = 0.1) {
        resumeWait(with: .timedOut(elapsed: elapsed))
    }

    private func resumeWait(with result: AgentReadyWaitResult) {
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume(returning: result)
        } else {
            pendingWaitResult = result
        }
    }
}
