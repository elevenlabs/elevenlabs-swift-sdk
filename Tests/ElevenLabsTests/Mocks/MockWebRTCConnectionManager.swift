@testable import ElevenLabs
import Foundation
import LiveKit

final class MockWebRTCConnectionManager: WebRTCConnectionManaging {
    enum Error: Swift.Error {
        case connectionFailed
        case publishFailed
    }

    var onDisconnected: (() async -> Void)?
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)? {
        didSet {
            if onEventReceived != nil {
                eventHandlerInstalled?.resume()
                eventHandlerInstalled = nil
            }
        }
    }

    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?

    private var eventHandlerInstalled: CheckedContinuation<Void, Never>?

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
    private(set) var lastNetworkConfiguration: WebRTCConfiguration = .default
    private(set) var lastWaitTimeout: TimeInterval = 0
    private(set) var publishedPayloads: [Data] = []

    private var waitContinuation: CheckedContinuation<AgentReadyWaitResult, Never>?
    private var pendingWaitResult: AgentReadyWaitResult?

    /// When `true` (the default), `waitForAgentReady` resolves immediately. Set to `false`
    /// only when a test needs to drive readiness via `succeedAgentReady`/`timeoutAgentReady`.
    var autoSucceedAgentReady = true

    /// Simulates the full WebRTC startup (token → room → agent → init), driven by
    /// the `tokenError`/`shouldFailConnection`/`publishError` flags and the
    /// agent-ready continuation (`succeedAgentReady`/`timeoutAgentReady`).
    @MainActor
    func connect(
        auth: ConversationCredentials,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> StartupResult {
        connectCallCount += 1
        lastNetworkConfiguration = config.networkConfiguration
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

        onStartupStateChange(.waitingForAgent(timeout: config.startupConfiguration.agentReadyTimeout))
        switch await waitForAgentReady(timeout: config.startupConfiguration.agentReadyTimeout) {
        case let .success(elapsed):
            metrics.agentReady = elapsed
            onStartupStateChange(.agentReady(ConversationAgentReadyReport(elapsed: elapsed)))
        case let .timedOut(elapsed):
            metrics.agentReady = elapsed
            throw StartupFailure.agentTimeout(metrics)
        }

        onStartupStateChange(.sendingConversationInit(attempt: 1))
        do {
            try await send(event: .conversationInit(ConversationInitEvent(config: config)))
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
        if autoSucceedAgentReady {
            return .success(elapsed: 0)
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

    /// Delivers an already-decoded event directly to the installed handler
    func deliver(_ event: IncomingEvent) {
        onEventReceived?(event)
    }

    /// Suspends until `onEventReceived` is set.
    func waitForEventHandlerInstalled() async {
        if onEventReceived != nil { return }
        await withCheckedContinuation { eventHandlerInstalled = $0 }
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
