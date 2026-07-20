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
    var onTracksChanged: (@Sendable () -> Void)?
    private var initiationMetadataWaiter: ConversationInitiationMetadataWaiter?

    private var eventHandlerInstalled: CheckedContinuation<Void, Never>?

    var room: Room?

    var inputTrack: (any AudioTrackProtocol)?
    var agentAudioTrack: (any AudioTrackProtocol)?
    var isMicrophoneMuted = true

    var errorHandler: ((Swift.Error?) -> Void)?
    var onDisconnectStarted: (@MainActor () async -> Void)?

    var shouldFailConnection = false
    var connectionError: Swift.Error = Error.connectionFailed
    var tokenError: ConversationError?
    var publishError: Swift.Error?
    var microphoneError: Swift.Error?
    var autoDeliverInitiationMetadata = true
    var initiationMetadataConversationId = "test-conversation-id"

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastNetworkConfiguration: WebRTCConfiguration = .default
    private(set) var lastWaitTimeout: TimeInterval = 0
    private(set) var publishedPayloads: [Data] = []
    private var startupStateChange: ((ConversationStartupState) -> Void)?

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
    ) async throws -> ConversationStartResult {
        startupStateChange = onStartupStateChange
        await initiationMetadataWaiter?.cancel()
        let waiter = ConversationInitiationMetadataWaiter(
            timeout: config.startupConfiguration.initiationMetadataTimeout
        )
        initiationMetadataWaiter = waiter
        let startTime = Date()
        connectCallCount += 1
        lastNetworkConfiguration = config.networkConfiguration
        var metrics = ConversationStartupMetrics()

        onStartupStateChange(.resolvingToken)
        if let tokenError {
            throw tokenError
        }

        onStartupStateChange(.connectingRoom)
        if shouldFailConnection {
            errorHandler?(connectionError)
            throw connectionError as? ConversationError ?? .connectionFailed(connectionError)
        }
        room = Room()

        onStartupStateChange(.waitingForAgent(timeout: config.startupConfiguration.agentReadyTimeout))
        switch await waitForAgentReady(timeout: config.startupConfiguration.agentReadyTimeout) {
        case let .success(elapsed):
            metrics.agentReady = elapsed
            onStartupStateChange(.agentReady(ConversationAgentReadyReport(elapsed: elapsed)))
        case let .timedOut(elapsed):
            metrics.agentReady = elapsed
            throw ConversationError.agentTimeout
        case let .cancelled(elapsed):
            metrics.agentReady = elapsed
            throw CancellationError()
        }

        onStartupStateChange(.sendingConversationInit)
        do {
            try await send(event: .conversationInit(ConversationInitEvent(config: config)))
        } catch {
            throw error as? ConversationError ?? ConversationError.connectionFailed(error)
        }

        if autoDeliverInitiationMetadata {
            let metadata = makeInitiationMetadata()
            await waiter.observe(metadata)
            onEventReceived?(.conversationMetadata(metadata))
        }

        let metadata = try await waitForInitiationMetadata(
            config: config,
            metrics: &metrics,
            startTime: startTime,
            metadataWaiter: waiter,
            onStartupStateChange: onStartupStateChange
        )
        return ConversationStartResult(
            callInfo: CallInfo(agentId: auth.agentId, conversationId: metadata.conversationId),
            metrics: metrics
        )
    }

    func deliverStartupState(_ state: ConversationStartupState) {
        startupStateChange?(state)
    }

    func disconnect() async {
        disconnectCallCount += 1
        await onDisconnectStarted?()
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil
        onRemoteSpeakingChanged = nil
        onTracksChanged = nil
        room = nil
        // Only cancel an in-flight agent-ready wait — don't stash `.cancelled` for the next connect.
        if waitContinuation != nil {
            await cancelAgentReady(elapsed: 0)
        }
        await initiationMetadataWaiter?.cancel()
        initiationMetadataWaiter = nil
    }

    @MainActor
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
        guard let initiationMetadataWaiter else {
            preconditionFailure("Cannot receive data before connecting")
        }
        handleIncomingData(
            data,
            metadataWaiter: initiationMetadataWaiter,
            logger: SDKLogger(logLevel: .error)
        )
    }

    /// Delivers an already-decoded event directly to the installed handler
    func deliver(_ event: IncomingEvent) {
        onEventReceived?(event)
    }

    /// Suspends until `onEventReceived` is set.
    @MainActor
    func waitForEventHandlerInstalled() async {
        if onEventReceived != nil { return }
        await withCheckedContinuation { eventHandlerInstalled = $0 }
    }

    @MainActor
    func succeedAgentReady(elapsed: TimeInterval = 0.1) {
        resumeWait(with: .success(elapsed: elapsed))
    }

    @MainActor
    func timeoutAgentReady(elapsed: TimeInterval = 0.1) {
        resumeWait(with: .timedOut(elapsed: elapsed))
    }

    @MainActor
    func cancelAgentReady(elapsed: TimeInterval = 0.1) {
        resumeWait(with: .cancelled(elapsed: elapsed))
    }

    @MainActor
    private func resumeWait(with result: AgentReadyWaitResult) {
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume(returning: result)
        } else {
            pendingWaitResult = result
        }
    }

    private func makeInitiationMetadata() -> ConversationMetadataEvent {
        ConversationMetadataEvent(
            conversationId: initiationMetadataConversationId,
            agentOutputAudioFormat: "pcm_16000",
            userInputAudioFormat: "pcm_16000"
        )
    }
}
