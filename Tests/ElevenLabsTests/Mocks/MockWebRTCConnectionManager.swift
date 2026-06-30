@testable import ElevenLabs
import Foundation
import LiveKit

/// Scriptable test double for `WebRTCConnectionManaging`.
///
/// `connect` mirrors the externally observable contract of the production
/// manager: it resolves a token, connects a room, waits for the agent, then
/// sends the conversation-init handshake — surfacing each stage's failure as a
/// `StartupFailure` so `Conversation`'s `handleStartupFailure` path is exercised.
/// Tests drive the agent-ready step with `succeedAgentReady()` / `timeoutAgentReady()`.
@MainActor
final class MockWebRTCConnectionManager: WebRTCConnectionManaging {
    enum Error: Swift.Error {
        case connectionFailed
        case publishFailed
    }

    var onDisconnected: (() async -> Void)?
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onRawMessage: (@Sendable (Data, IncomingEvent?) -> Void)?
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?
    var onTracksChanged: (@Sendable () -> Void)?
    var onStartupPhaseChange: ((StartupPhase) -> Void)?

    /// When true, `connect` synthesizes a `conversation_initiation_metadata`
    /// event on success so the production startup gate (which blocks until the
    /// metadata arrives) completes. Set to false to drive metadata manually.
    var autoDeliverMetadata = true
    var metadataConversationId = "mock-conversation-id"

    var room: Room?

    var inputTrack: LocalAudioTrack?
    var agentAudioTrack: RemoteAudioTrack?
    var isMicrophoneMuted = true

    /// Inject a failure at the token-resolution stage.
    var tokenError: Swift.Error?
    /// Inject a failure at the room-connect stage.
    var shouldFailConnection = false
    var connectionError: Swift.Error = Error.connectionFailed
    /// Inject a failure at the conversation-init publish stage.
    var publishError: Swift.Error?
    var microphoneError: Swift.Error?

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastAuth: ConversationAuth?
    private(set) var lastConfig: ConversationConfig?
    private(set) var lastWaitTimeout: TimeInterval = 0
    private(set) var publishedPayloads: [Data] = []

    private var waitContinuation: CheckedContinuation<Bool, Never>?
    private var pendingWaitResult: Bool?

    func connect(auth: ConversationAuth, config: ConversationConfig) async throws {
        connectCallCount += 1
        lastAuth = auth
        lastConfig = config

        // Token stage.
        if let tokenError {
            let convError = tokenError as? ConversationError ?? .authenticationFailed("\(tokenError)")
            throw ConversationStartupFailure.token(convError)
        }

        // Room-connect stage.
        if shouldFailConnection {
            let convError = connectionError as? ConversationError ?? .connectionFailed(connectionError)
            throw ConversationStartupFailure.room(convError)
        }
        room = Room()

        // Wait for the agent (driven by the test via succeed/timeout helpers).
        guard await waitForAgentReady(timeout: config.agentJoinTimeout) else {
            throw ConversationStartupFailure.agentTimeout
        }

        // Conversation-init publish stage.
        if let publishError {
            let convError = publishError as? ConversationError ?? .connectionFailed(publishError)
            throw ConversationStartupFailure.conversationInit(convError)
        }
        let initEvent = ConversationInitEvent(config: config)
        publishedPayloads.append(try EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))

        deliverMetadataIfNeeded()
    }

    func disconnect() async {
        disconnectCallCount += 1
        onEventReceived = nil
        onRawMessage = nil
        onDisconnected = nil
        onRemoteSpeakingChanged = nil
        onTracksChanged = nil
        onStartupPhaseChange = nil
        room = nil
        // Mirror production: disconnect releases any in-flight agent-ready wait
        // (the readiness delegate is cancelled), which `waitForAgentReady`
        // observes as `false`.
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume(returning: false)
        }
    }

    func waitForAgentReady(timeout: TimeInterval) async -> Bool {
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
            throw publishError
        }
        publishedPayloads.append(data)
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard room != nil else {
            throw ConnectionManagerError.notConnected
        }
        if let microphoneError {
            throw microphoneError
        }
        isMicrophoneMuted = muted
    }

    // MARK: - Helpers

    func receive(data: Data) {
        handleIncomingData(data, logger: SDKLogger(levelOverride: .error))
    }

    private func deliverMetadataIfNeeded() {
        guard autoDeliverMetadata else { return }
        onEventReceived?(.conversationMetadata(ConversationMetadataEvent(
            conversationId: metadataConversationId,
            agentOutputAudioFormat: "pcm_16000",
            userInputAudioFormat: "pcm_16000"
        )))
    }

    func succeedAgentReady() {
        resumeWait(with: true)
    }

    func timeoutAgentReady() {
        resumeWait(with: false)
    }

    private func resumeWait(with result: Bool) {
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume(returning: result)
        } else {
            pendingWaitResult = result
        }
    }
}
