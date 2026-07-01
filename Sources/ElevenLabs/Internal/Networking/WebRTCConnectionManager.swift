import AVFoundation
import Foundation
import LiveKit

enum AgentReadyWaitResult: Equatable {
    case success(elapsed: TimeInterval)
    case timedOut(elapsed: TimeInterval)
}

enum WebRTCConnectionManagerError: Error {
    case roomUnavailable
}

/// Façade around `LiveKit.Room`.
///
/// Owns the room lifecycle, microphone control, data publish/receive, and
/// surfaces a small set of typed callbacks (connection state, remote speaking,
/// remote disconnect) plus an async readiness API.
///
/// LiveKit observation is split across two `RoomDelegate` instances:
/// - `LiveKitRoomEventDelegate` — data, speaking, remote disconnect
/// - `LiveKitReadinessDelegate` — signals when the agent's audio track subscribes
///
/// Note: `Room`, `LocalAudioTrack`, and `RemoteAudioTrack` are intentionally
/// exposed on the public SDK surface (e.g. `Conversation.inputTrack`), so this
/// type does not fully hide LiveKit from callers. It does centralize the
/// dependency in one place.
final class WebRTCConnectionManager: WebRTCConnectionManaging {
    /// Fired when the remote agent leaves, the room disconnects, or all remote participants are gone.
    var onDisconnected: (() async -> Void)?

    /// Fired when LiveKit receives and parses a protocol event from the room.
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?

    /// Fired when a remote participant starts or stops speaking.
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?

    var errorHandler: ((Swift.Error?) -> Void)?

    // MARK: – Public state accessors

    private(set) var room: Room?

    var inputTrack: LocalAudioTrack? {
        room?.localParticipant.firstAudioPublication?.track as? LocalAudioTrack
    }

    var agentAudioTrack: RemoteAudioTrack? {
        room?.remoteParticipants.values.first?.firstAudioPublication?.track as? RemoteAudioTrack
    }

    var isMicrophoneMuted: Bool {
        guard let room else { return true }
        return !room.localParticipant.isMicrophoneEnabled()
    }

    // MARK: – Private

    private var eventDelegate: LiveKitRoomEventDelegate?
    private var readinessDelegate: LiveKitReadinessDelegate?

    private static let reliableDataPublishOptions = DataPublishOptions(reliable: true)

    private let logger: any Logging
    private let tokenService: any TokenServicing

    init(logger: any Logging, tokenService: any TokenServicing) {
        self.logger = logger
        self.tokenService = tokenService
    }

    // MARK: – Public API

    /// Full WebRTC startup sequence: resolve token → request mic permission →
    /// connect room → wait for agent → send conversation_init (sent once).
    @MainActor
    func connect(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> StartupResult {
        let startTime = Date()
        var metrics = ConversationStartupMetrics()
        logger.info("Starting conversation startup sequence", context: ["agentId": auth.agentId])

        // 1. Resolve token / connection details.
        onStartupStateChange(.resolvingToken)
        let connectionDetails = try await runPhase(
            timing: \.tokenFetch, metrics: &metrics, startTime: startTime, failure: StartupFailure.token
        ) {
            try await tokenService.fetchConnectionDetails(configuration: auth)
        }

        // 2. Request microphone permission (denial doesn't block startup).
        let permissionGranted = await Self.requestMicrophonePermission()

        // 3. Connect the LiveKit room.
        onStartupStateChange(.connectingRoom)
        let throwOnMicFailure = options.microphoneFailureHandling == .throwError
        try await runPhase(
            timing: \.roomConnect, metrics: &metrics, startTime: startTime, failure: StartupFailure.room
        ) {
            try await connectToRoom(
                details: connectionDetails,
                enableMic: permissionGranted,
                throwOnMicrophoneFailure: throwOnMicFailure,
                networkConfiguration: options.networkConfiguration
            )
        }

        // 4. Wait for the agent to be ready (fails outright if it doesn't join in time).
        let agentTimeout = options.startupConfiguration.agentReadyTimeout
        onStartupStateChange(.waitingForAgent(timeout: agentTimeout))
        guard case let .success(elapsed) = await waitForAgentReady(timeout: agentTimeout) else {
            metrics.total = Date().timeIntervalSince(startTime)
            logger.warning("Agent not ready within \(String(format: "%.3f", agentTimeout))s")
            throw StartupFailure.agentTimeout(metrics)
        }
        metrics.agentReady = elapsed
        onStartupStateChange(.agentReady(ConversationAgentReadyReport(elapsed: elapsed)))

        // 5. Send conversation_initiation_client_data (sent once).
        onStartupStateChange(.sendingConversationInit(attempt: 1))
        try await runPhase(
            timing: \.conversationInit, metrics: &metrics, startTime: startTime,
            failure: StartupFailure.conversationInit
        ) {
            try await send(event: .conversationInit(ConversationInitEvent(config: options.toConversationConfig())))
        }
        metrics.conversationInitAttempts = 1

        metrics.total = Date().timeIntervalSince(startTime)
        return StartupResult(agentId: auth.agentId, metrics: metrics)
    }

    /// Race the delegate's "agent audio track subscribed" signal against `timeout`.
    /// A `.timedOut` result makes `connect` fail with `StartupFailure.agentTimeout`.
    private func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult {
        guard let delegate = readinessDelegate else {
            return .timedOut(elapsed: 0)
        }
        let start = Date()
        return await withTaskGroup(of: AgentReadyWaitResult.self) { group in
            group.addTask {
                do {
                    try await delegate.awaitSubscription()
                    return .success(elapsed: Date().timeIntervalSince(start))
                } catch {
                    return .timedOut(elapsed: Date().timeIntervalSince(start))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut(elapsed: Date().timeIntervalSince(start))
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    func send(data: Data) async throws {
        guard let room else {
            throw ConnectionManagerError.notConnected
        }
        do {
            try await room.localParticipant.publish(data: data, options: Self.reliableDataPublishOptions)
        } catch {
            errorHandler?(error)
            throw error
        }
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard let room else {
            throw WebRTCConnectionManagerError.roomUnavailable
        }
        do {
            try await room.localParticipant.setMicrophone(enabled: !muted)
        } catch {
            errorHandler?(error)
            throw error
        }
    }

    /// Establish the LiveKit room connection (the low-level room/mic primitive
    /// used by `connect`).
    ///
    /// - Parameters:
    ///   - details: Token-service credentials (URL + participant token).
    ///   - enableMic: Whether to enable the local microphone immediately.
    ///   - throwOnMicrophoneFailure: If true, throws error when microphone setup fails.
    ///     If false, logs warning and continues.
    private func connectToRoom(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool,
        networkConfiguration: LiveKitNetworkConfiguration
    ) async throws {
        await readinessDelegate?.release()

        let readinessDelegate = await LiveKitReadinessDelegate(logger: logger)
        self.readinessDelegate = readinessDelegate

        let logger = logger
        let eventDelegate = LiveKitRoomEventDelegate(
            onData: { [weak self] data in self?.handleIncomingData(data, logger: logger) },
            onRemoteSpeaking: { [weak self] isSpeaking in self?.onRemoteSpeakingChanged?(isSpeaking) },
            onRemoteDisconnect: { [weak self] in await self?.onDisconnected?() }
        )
        self.eventDelegate = eventDelegate

        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        self.room = room
        room.delegates.add(delegate: eventDelegate)
        room.delegates.add(delegate: readinessDelegate)

        let connectOptions = await networkConfiguration.makeConnectOptions()

        let connectStart = Date()
        do {
            try await room.connect(
                url: details.serverUrl,
                token: details.participantToken,
                connectOptions: connectOptions
            )
            logger.info("LiveKit room.connect completed", context: ["duration": "\(Date().timeIntervalSince(connectStart))"])
        } catch {
            logger.error("LiveKit room.connect failed", context: ["error": "\(error)"])
            errorHandler?(error)
            if await LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission() {
                errorHandler?(ConversationError.localNetworkPermissionRequired)
            }
            throw error
        }

        if enableMic {
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                logger.info("Microphone enabled successfully")
            } catch {
                logger.error("Failed to enable microphone", context: ["error": "\(error)"])
                errorHandler?(error)

                if throwOnMicrophoneFailure {
                    throw ConversationError.microphoneToggleFailed(error)
                } else {
                    logger.warning("Continuing without microphone due to error handling policy")
                }
            }
        }
    }

    /// Disconnect and tear down.
    func disconnect() async {
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil
        onRemoteSpeakingChanged = nil

        await readinessDelegate?.release()
        readinessDelegate = nil

        await room?.disconnect()
        room = nil
        eventDelegate = nil
    }

    // MARK: – Private helpers

    /// Run one timed startup phase: record its duration into `metrics[keyPath:]`,
    /// let `CancellationError` propagate unwrapped, and wrap any other error via
    /// `failure` (stamping `total`).
    @MainActor
    private func runPhase<T>(
        timing keyPath: WritableKeyPath<ConversationStartupMetrics, TimeInterval?>,
        metrics: inout ConversationStartupMetrics,
        startTime: Date,
        failure: (ConversationError, ConversationStartupMetrics) -> StartupFailure,
        _ body: () async throws -> T
    ) async throws -> T {
        let start = Date()
        do {
            let result = try await body()
            metrics[keyPath: keyPath] = Date().timeIntervalSince(start)
            return result
        } catch is CancellationError {
            metrics[keyPath: keyPath] = Date().timeIntervalSince(start)
            metrics.total = Date().timeIntervalSince(startTime)
            throw CancellationError()
        } catch {
            metrics[keyPath: keyPath] = Date().timeIntervalSince(start)
            metrics.total = Date().timeIntervalSince(startTime)
            throw failure(error as? ConversationError ?? .connectionFailed(error), metrics)
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
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
        #elseif os(visionOS)
        return await AVAudioApplication.requestRecordPermission()
        #elseif os(tvOS)
        return false
        #else
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
}

// MARK: – Room event delegate

/// `RoomDelegate` that forwards data, remote speaking, and remote-disconnect events
/// (agent leaving or room disconnect) to manager-supplied closures.
final class LiveKitRoomEventDelegate: RoomDelegate {
    private let onData: @Sendable (Data) -> Void
    private let onRemoteSpeaking: @Sendable (Bool) -> Void
    private let onRemoteDisconnect: @Sendable () async -> Void

    init(
        onData: @escaping @Sendable (Data) -> Void,
        onRemoteSpeaking: @escaping @Sendable (Bool) -> Void,
        onRemoteDisconnect: @escaping @Sendable () async -> Void
    ) {
        self.onData = onData
        self.onRemoteSpeaking = onRemoteSpeaking
        self.onRemoteDisconnect = onRemoteDisconnect
    }

    nonisolated func room(
        _: Room, participant _: RemoteParticipant?, didReceiveData data: Data,
        forTopic _: String, encryptionType _: EncryptionType
    ) {
        onData(data)
    }

    nonisolated func room(_: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        // The agent is a remote participant, so any active remote speaker means it's speaking.
        onRemoteSpeaking(participants.contains { $0 is RemoteParticipant })
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identityString = participant.identity.map { String(describing: $0) } ?? ""
        guard identityString.hasPrefix("agent") || room.remoteParticipants.isEmpty else { return }
        Task { [onRemoteDisconnect] in
            await onRemoteDisconnect()
        }
    }

    nonisolated func room(_: Room, didUpdateConnectionState state: ConnectionState, from _: ConnectionState) {
        guard state == .disconnected else { return }
        Task { [onRemoteDisconnect] in
            await onRemoteDisconnect()
        }
    }
}

// MARK: – Readiness delegate

/// Observes LiveKit and signals exactly one event: the agent's audio track is
/// subscribed (the real "safe to send" signal). Holds no timing policy; callers
/// race `awaitSubscription()` against their own timeout.
@MainActor
private final class LiveKitReadinessDelegate: RoomDelegate {
    private enum Stage { case waiting, ready, released }

    private let logger: any Logging
    private var stage: Stage = .waiting
    private var awaiter: CheckedContinuation<Void, Error>?

    init(logger: any Logging) {
        self.logger = logger
    }

    /// Suspend until the agent's audio track is subscribed. Throws `CancellationError`
    /// if the awaiting task is cancelled or `release()` is called (e.g. on disconnect).
    /// Single-caller — there's exactly one `waitForAgentReady` per connection lifetime.
    func awaitSubscription() async throws {
        switch stage {
        case .ready: return
        case .released: throw CancellationError()
        case .waiting: break
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                switch stage {
                case .ready: cont.resume()
                case .released: cont.resume(throwing: CancellationError())
                case .waiting: awaiter = cont
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let cont = self?.awaiter {
                    self?.awaiter = nil
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// Resolve the in-flight awaiter (if any) with `CancellationError`. Called by
    /// the manager on disconnect (or before swapping in a fresh delegate on reconnect).
    func release() {
        guard stage != .released else { return }
        stage = .released
        if let cont = awaiter {
            awaiter = nil
            cont.resume(throwing: CancellationError())
        }
    }

    // MARK: - RoomDelegate

    nonisolated func roomDidConnect(_ room: Room) {
        Task { @MainActor in self.checkForSubscribedAudio(in: room) }
    }

    nonisolated func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
        Task { @MainActor in self.checkForSubscribedAudio(in: room) }
    }

    nonisolated func room(
        _: Room,
        participant _: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in
            guard publication.kind == .audio else { return }
            self.markReady()
        }
    }

    // MARK: - Private

    private func checkForSubscribedAudio(in room: Room) {
        guard stage == .waiting else { return }
        let hasSubscribed = room.remoteParticipants.values.contains { participant in
            participant.audioTracks.contains { $0.isSubscribed && $0.track != nil }
        }
        if hasSubscribed { markReady() }
    }

    private func markReady() {
        guard stage == .waiting else { return }
        stage = .ready
        logger.debug("Agent audio track subscribed")
        if let cont = awaiter {
            awaiter = nil
            cont.resume()
        }
    }
}
