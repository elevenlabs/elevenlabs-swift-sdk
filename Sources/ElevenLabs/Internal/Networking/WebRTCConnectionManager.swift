import Foundation
import AVFoundation
import LiveKit

/// Façade around `LiveKit.Room`.
///
/// Owns the room lifecycle, microphone control, data publish/receive, and
/// surfaces a small set of typed callbacks (connection state, remote speaking,
/// remote disconnect) plus an async readiness API.
///
/// LiveKit observation is split across two `RoomDelegate` instances:
/// - `LiveKitRoomEventDelegate` — data, speaking, remote disconnect
/// - `LiveKitReadinessDelegate` — signals when the agent's audio track subscribes
@MainActor
final class WebRTCConnectionManager: WebRTCConnectionManaging {
    /// Fired when the remote agent leaves, the room disconnects, or all remote participants are gone.
    var onDisconnected: (() async -> Void)?

    /// Fired when LiveKit receives and parses a protocol event from the room.
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?

    /// Raw tap on every incoming data-channel frame, carrying the original bytes
    /// and the parsed event (`nil` when unknown/unparseable).
    var onRawMessage: (@Sendable (Data, IncomingEvent?) -> Void)?

    /// Fired when a remote participant starts or stops speaking.
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?

    /// Reports startup-phase transitions during `connect`.
    var onStartupPhaseChange: ((StartupPhase) -> Void)?

    // MARK: – Public state accessors

    private(set) var room: Room?

    var inputTrack: LocalAudioTrack? {
        room?.localParticipant.firstAudioPublication?.track as? LocalAudioTrack
    }

    var agentAudioTrack: RemoteAudioTrack? {
        agentParticipant?.firstAudioPublication?.track as? RemoteAudioTrack
    }

    /// The agent's remote participant, identified by the `agent` identity prefix
    /// the orchestrator assigns. Falls back to the sole remote participant since
    /// a conversation only ever has the agent on the far side.
    private var agentParticipant: RemoteParticipant? {
        let remotes = room?.remoteParticipants.values
        return remotes?.first(where: Self.isAgentParticipant) ?? remotes?.first
    }

    /// Identity-prefix the orchestrator uses to name the agent participant.
    private nonisolated static let agentIdentityPrefix = "agent"

    /// Whether `participant` is the agent, by its identity prefix. Shared by the
    /// track accessor and the disconnect delegate so both agree on what "agent"
    /// means.
    nonisolated static func isAgentParticipant(_ participant: Participant) -> Bool {
        guard let identity = participant.identity else { return false }
        return String(describing: identity).hasPrefix(agentIdentityPrefix)
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
    private let tokenService: TokenServicing

    init(logger: any Logging, tokenService: TokenServicing) {
        self.logger = logger
        self.tokenService = tokenService
    }

    // MARK: – Public API

    /// Establish the LiveKit connection and send the conversation-init handshake,
    /// driving `onStartupPhaseChange` through the startup sequence.
    func connect(
        auth: ConversationAuth,
        config: ConversationConfig
    ) async throws {
        let endpoints = config.endpoints
        // Connect-phase timings, emitted via `logger.debug` at the end of connect.
        let tStart = Date()

        // Authorizing: fetch the LiveKit token (mic permission resolves
        // concurrently just below).
        onStartupPhaseChange?(.authorizing)

        // Create the room and register delegates before connecting, so the
        // readiness delegate is in place to observe the agent joining.
        readinessDelegate?.release()

        let readinessDelegate = LiveKitReadinessDelegate(logger: logger)
        self.readinessDelegate = readinessDelegate

        let logger = logger
        let eventDelegate = LiveKitRoomEventDelegate(
            onData: { [weak self] data in
                Task { @MainActor in self?.handleIncomingData(data, logger: logger) }
            },
            onRemoteSpeaking: { [weak self] isSpeaking in
                Task { @MainActor in self?.onRemoteSpeakingChanged?(isSpeaking) }
            },
            onRemoteDisconnect: { [weak self] in await self?.notifyDisconnected() }
        )
        self.eventDelegate = eventDelegate

        let room = Room(
            roomOptions: RoomOptions(singlePeerConnection: true)
        )
        self.room = room
        room.delegates.add(delegate: eventDelegate)
        room.delegates.add(delegate: readinessDelegate)

        // Resolve mic permission concurrently with the token fetch: on a cold
        // grant the prompt overlaps the token round-trip instead of running
        // serially after it.
        let voiceURL = endpoints.voiceWebSocket.absoluteString
        async let micPermissionGranted = requestMicrophonePermission()

        let roomToken: String
        let tTokenStart = Date()
        do {
            roomToken = try await tokenService.fetchRoomToken(
                auth: auth,
                apiBase: endpoints.apiBase,
                environment: config.environment
            )
            logger.debug("Token fetch successful")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Throws during `connect` are surfaced as `ConversationStartupFailure`
            // so `Conversation.handleStartupFailure` can disconnect, reset to
            // `.idle`, and report once via `onError`. A bare throw would escape
            // that and leave the session wedged in `.connecting`.
            let conversationError: ConversationError
            switch error {
            case let error as ConversationError:
                conversationError = error
            case let error as TokenError:
                conversationError = switch error {
                case .authenticationFailed:
                    .authenticationFailed(error.localizedDescription)
                case let .httpError(statusCode):
                    .authenticationFailed("HTTP error: \(statusCode)")
                case .invalidURL, .invalidResponse, .invalidTokenResponse:
                    .authenticationFailed(error.localizedDescription)
                }
            default:
                conversationError = .connectionFailed(error)
            }
            throw ConversationStartupFailure.token(conversationError)
        }

        let tToken = Date()

        // Network work is done; report the user-input wait as its own phase
        // (distinct from the network-bound `.authorizing`) before blocking on the
        // permission result.
        onStartupPhaseChange?(.requestingMicPermission)
        let enableMic = await micPermissionGranted
        let tReady = Date()

        // No mic permission for a voice conversation. iOS only prompts once, so a
        // denial is terminal until re-enabled in Settings. Fail fast before
        // connecting a room we can't use.
        if !enableMic, config.microphoneFailureHandling == .throwError {
            throw ConversationStartupFailure.microphone(.microphonePermissionDenied)
        }

        let connectOptions = Self.makeConnectOptions(for: config)

        // Connecting: establish the LiveKit room and (below) enable the mic.
        onStartupPhaseChange?(.connecting)

        do {
            try await room.connect(
                url: voiceURL,
                token: roomToken,
                connectOptions: connectOptions
            )
            logger.info("LiveKit room.connect completed")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("LiveKit room.connect failed", context: ["error": "\(error)"])
            throw ConversationStartupFailure.room(.connectionFailed(error))
        }
        let tConnect = Date()

        // Diagnostics — is the capture engine already warm before we publish?
        let micEngineWarm = AudioManager.shared.isEngineRunning
        let micPrepared = AudioManager.shared.isRecordingAlwaysPreparedMode

        // TODO(perf): the engine is cold here (`isEngineRunning == false`) despite
        // prepared-mode, which only keeps recording *initialized*. Starting capture
        // overlapped with `room.connect` would let this publish reuse a hot engine
        // (~415ms saved on device), at the cost of the mic going hot ~800ms earlier
        // and needing matching teardown on disconnect/failure.
        if enableMic {
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                logger.info("Microphone enabled successfully")
            } catch {
                // `setMicrophone` starts the engine eagerly only to surface
                // failures early; WebRTC re-inits recording itself once media
                // flows. The errors are deterministic (permission, session
                // category), so there's nothing to retry — honor the policy.
                logger.error("Failed to enable microphone", context: ["error": "\(error)"])
                if config.microphoneFailureHandling == .throwError {
                    throw ConversationStartupFailure.microphone(
                        ConversationError.microphoneToggleFailed(error)
                    )
                } else {
                    // `.continueWithoutMicrophone`: log and proceed.
                    logger.warning("Continuing without microphone due to error handling policy")
                }
            }
        }
        let tMic = Date()

        // Wait for the agent (remote participant) to join before sending init: a
        // reliable data message only reaches participants present at publish time,
        // so sending into an empty room would silently drop the handshake.
        onStartupPhaseChange?(.waitingForAgent(timeout: config.agentJoinTimeout))
        guard await waitForAgentReady(timeout: config.agentJoinTimeout) else {
            throw ConversationStartupFailure.agentTimeout
        }

        // Sending the conversation_initiation_client_data handshake.
        onStartupPhaseChange?(.sendingInitData)

        // A single send is sufficient: LiveKit buffers the data packet until the
        // publisher channel opens and errors out if the connection resets, so no
        // poll/retry is needed.
        let initEvent = ConversationInitEvent(config: config)
        do {
            try await send(event: .conversationInit(initEvent))
            logger.debug("Conversation init sent")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Conversation init failed", context: ["error": "\(error)"])
            let convError = error as? ConversationError ?? .connectionFailed(error)
            throw ConversationStartupFailure.conversationInit(convError)
        }
        let tInit = Date()

        func ms(_ from: Date, _ to: Date) -> String { String(format: "%.0f", to.timeIntervalSince(from) * 1000) }
        logger.debug("Startup timings", context: [
            "token_ms": ms(tTokenStart, tToken),
            "token_perm_ms": ms(tStart, tReady),
            "connect_ms": ms(tReady, tConnect),
            "mic_ms": ms(tConnect, tMic),
            "mic_warm": "\(micEngineWarm)",
            "mic_prepared": "\(micPrepared)",
            "init_ms": ms(tMic, tInit),
            "total_ms": ms(tStart, tInit),
        ])
    }

    /// Hop to the actor and fire the (async) disconnect callback. Used by the
    /// non-isolated room delegate so it never touches manager state off-actor.
    private func notifyDisconnected() async {
        await onDisconnected?()
    }

    /// Disconnect and tear down.
    func disconnect() async {
        onEventReceived = nil
        onRawMessage = nil
        onDisconnected = nil
        onRemoteSpeakingChanged = nil
        onStartupPhaseChange = nil

        readinessDelegate?.release()
        readinessDelegate = nil

        await room?.disconnect()
        room = nil
        eventDelegate = nil
    }

    /// Race the delegate's "first remote participant joined" signal against
    /// `timeout`. Returns `true` once the agent joins, or `false` if it doesn't
    /// arrive in time. Internal to `connect`'s startup sequence.
    private func waitForAgentReady(timeout: TimeInterval) async -> Bool {
        guard let delegate = readinessDelegate else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await delegate.awaitRemoteParticipant()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Map ``ConversationConfig`` onto LiveKit connect options, or `nil` to use
    /// LiveKit's default ICE behaviour (gather *all* candidate types — host,
    /// server-reflexive, and relay).
    ///
    /// We deliberately keep the full candidate set by default. It's tempting to
    /// assume host candidates are useless against a cloud media server, but on
    /// real networks (notably IPv6 / CGNAT, where the server-reflexive candidate
    /// is redundant with — and suppressed in favour of — a globally routable
    /// host candidate) the host candidate is the path that actually connects.
    /// Dropping it (`.noHost`) can strand the session on relay-only and time out.
    ///
    /// ``ConversationConfig/relayOnly`` forces all media through TURN
    /// (``IceTransportPolicy/relay``) for networks that require it.
    private static func makeConnectOptions(for config: ConversationConfig) -> ConnectOptions? {
        guard config.relayOnly else { return nil }
        return ConnectOptions(iceTransportPolicy: .relay)
    }

    /// Request microphone permission, returning whether it is granted.
    private func requestMicrophonePermission() async -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil {
            logger.error(
                "NSMicrophoneUsageDescription is missing from your app's Info.plist. "
                    + "Voice features require this key. Add it to Info.plist or set "
                    + "INFOPLIST_KEY_NSMicrophoneUsageDescription in your build settings."
            )
            return false
        }

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

    func send(data: Data) async throws {
        guard let room else {
            throw ConnectionManagerError.notConnected
        }
        try await room.localParticipant.publish(data: data, options: Self.reliableDataPublishOptions)
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard let room else {
            throw ConnectionManagerError.notConnected
        }
        try await room.localParticipant.setMicrophone(enabled: !muted)
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
        // The agent is a remote participant, so any active remote speaker means it is speaking.
        onRemoteSpeaking(participants.contains { $0 is RemoteParticipant })
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard WebRTCConnectionManager.isAgentParticipant(participant) || room.remoteParticipants.isEmpty else { return }
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

/// Observes LiveKit and signals exactly one event: the first remote participant
/// has joined the room (the "safe to send" signal). Holds no timing policy; callers
/// race `awaitRemoteParticipant()` against their own timeout.
@MainActor
private final class LiveKitReadinessDelegate: RoomDelegate {
    private let logger: any Logging
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    init(logger: any Logging) {
        self.logger = logger
    }

    /// Suspend until the first remote participant joins. Throws `CancellationError`
    /// if the awaiting task is cancelled or `release()` is called (e.g. on disconnect).
    /// Single-caller — there's exactly one `waitForAgentReady` per connection lifetime.
    func awaitRemoteParticipant() async throws {
        if let outcome { return try outcome.get() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let outcome {
                    cont.resume(with: outcome)
                } else if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    continuation = cont
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    /// Resolve the in-flight awaiter (if any) with `CancellationError`. Called by
    /// the manager on disconnect (or before swapping in a fresh delegate on reconnect).
    func release() {
        finish(.failure(CancellationError()))
    }

    // MARK: - RoomDelegate

    nonisolated func roomDidConnect(_ room: Room) {
        Task { @MainActor in
            if !room.remoteParticipants.isEmpty { self.markReady() }
        }
    }

    nonisolated func room(_: Room, participantDidConnect _: RemoteParticipant) {
        Task { @MainActor in self.markReady() }
    }

    // MARK: - Private

    private func markReady() {
        logger.debug("Remote participant joined")
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
