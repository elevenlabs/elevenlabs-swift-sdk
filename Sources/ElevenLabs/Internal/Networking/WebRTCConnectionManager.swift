import Foundation
import LiveKit

struct AgentReadyDetail: Equatable {
    let elapsed: TimeInterval
    let viaGraceTimeout: Bool
}

enum AgentReadyWaitResult: Equatable {
    case success(AgentReadyDetail)
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

    init(logger: any Logging) {
        self.logger = logger
    }

    // MARK: – Public API

    /// Race the delegate's "agent audio track subscribed" signal against `timeout`.
    /// The caller (`AgentReadyStep`) decides whether `.timedOut` should throw or
    /// be promoted to `.success(viaGraceTimeout: true)`.
    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult {
        guard let delegate = readinessDelegate else {
            return .timedOut(elapsed: 0)
        }
        let start = Date()
        return await withTaskGroup(of: AgentReadyWaitResult.self) { group in
            group.addTask {
                do {
                    try await delegate.awaitSubscription()
                    return .success(AgentReadyDetail(
                        elapsed: Date().timeIntervalSince(start),
                        viaGraceTimeout: false
                    ))
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
        try await room.localParticipant.publish(data: data, options: Self.reliableDataPublishOptions)
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard let room else {
            throw WebRTCConnectionManagerError.roomUnavailable
        }
        try await room.localParticipant.setMicrophone(enabled: !muted)
    }

    /// Establish a LiveKit connection.
    ///
    /// - Parameters:
    ///   - details: Token-service credentials (URL + participant token).
    ///   - enableMic: Whether to enable the local microphone immediately.
    ///   - throwOnMicrophoneFailure: If true, throws error when microphone setup fails.
    ///     If false, logs warning and continues.
    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool = true,
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
            throw error
        }

        if enableMic {
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                logger.info("Microphone enabled successfully")
            } catch {
                logger.error("Failed to enable microphone", context: ["error": "\(error)"])

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
        onRemoteSpeakingChanged = nil

        await readinessDelegate?.release()
        readinessDelegate = nil

        await room?.disconnect()
        room = nil
        eventDelegate = nil
    }
}

// MARK: – Room event delegate

/// `RoomDelegate` that forwards data, remote speaking, and remote-disconnect events
/// (agent leaving or room disconnect) to manager-supplied closures.
private final class LiveKitRoomEventDelegate: RoomDelegate {
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

    nonisolated func room(_: Room, participant: Participant, didUpdateIsSpeaking isSpeaking: Bool) {
        guard participant is RemoteParticipant else { return }
        onRemoteSpeaking(isSpeaking)
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
