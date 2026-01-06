import Foundation
import LiveKit

// swiftlint:disable file_length

struct AgentReadyDetail: Equatable, Sendable {
    let elapsed: TimeInterval
    let viaGraceTimeout: Bool
}

enum AgentReadyWaitResult: Equatable, Sendable {
    case success(AgentReadyDetail)
    case timedOut(elapsed: TimeInterval)
}

enum ConnectionManagerError: Error {
    case roomUnavailable
}

/// **ConnectionManager**
///
/// A small façade around `LiveKit.Room` that emits **exactly one**
/// *agent‑ready* signal at the precise moment the remote agent is
/// reachable **and** at least one of its audio tracks is subscribed.
///
/// ▶︎ *Never too early*: we wait for both the participant *and* its track subscription.
/// ▶︎ *Never too late*: a short, configurable grace‑timeout prevents
///   indefinite waiting on networks where track subscription events can
///   be lost or delayed.
///
/// after the ready event fires you can safely send client‑initiation
/// metadata—​the remote side will be present and able to receive it.
///
/// **Architecture Note:**
/// This class isolates LiveKit dependency from the rest of the SDK. It uses an internal `ReadyDelegate`
/// actor to manage the complex state machine of connection + subscription + grace periods, converting
/// them into simple linear `async/await` flows for the consumer.
final class ConnectionManager: ConnectionManaging {
    /// Fired **once** when the remote agent is considered ready.
    var onAgentReady: (() -> Void)?

    /// Fired when all remote participants have left or the room disconnects.
    var onAgentDisconnected: (() -> Void)?

    // MARK: – Public state accessors

    private(set) var room: Room?

    var shouldObserveRoomConnection: Bool { true }

    // MARK: – Private

    private var readyDelegate: ReadyDelegate?
    private var readyStartTime: Date?
    private var lastReadyDetail: AgentReadyDetail?
    var errorHandler: (Swift.Error?) -> Void = { _ in }

    private struct ReadyAwaiter {
        let id: UUID
        let continuation: CheckedContinuation<AgentReadyWaitResult, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var readyAwaiters: [ReadyAwaiter] = []
    private let stateQueue = DispatchQueue(label: "com.elevenlabs.sdk.connection.state")

    private let logger: any Logging

    init(logger: any Logging) {
        self.logger = logger
    }

    // MARK: – Lifecycle

    private func resolveReadyAwaiters(with result: AgentReadyWaitResult) {
        var awaiters: [ReadyAwaiter] = []
        stateQueue.sync {
            guard !readyAwaiters.isEmpty else { return }
            awaiters = readyAwaiters
            readyAwaiters.removeAll()
        }
        for awaiter in awaiters {
            awaiter.timeoutTask.cancel()
            awaiter.continuation.resume(returning: result)
        }
    }

    private func resolveReadyAwaitersOnTimeout() {
        guard lastReadyDetail == nil else { return }
        let elapsed = Date().timeIntervalSince(readyStartTime ?? Date())
        resolveReadyAwaiters(with: .timedOut(elapsed: elapsed))
    }

    private func handleAgentReady(source: ReadyDelegate.ReadySource) {
        let elapsed = Date().timeIntervalSince(readyStartTime ?? Date())
        let detail = AgentReadyDetail(
            elapsed: elapsed,
            viaGraceTimeout: source == .graceTimeout
        )

        // cache for future waiters
        stateQueue.sync {
            if lastReadyDetail == nil {
                lastReadyDetail = detail
            }
        }

        resolveReadyAwaiters(with: .success(detail))
        readyStartTime = nil
        onAgentReady?()
    }

    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult {
        if let detail = lastReadyDetail {
            return .success(detail)
        }

        let start = readyStartTime ?? Date()
        if timeout <= 0 {
            return .timedOut(elapsed: Date().timeIntervalSince(start))
        }

        return await withCheckedContinuation { continuation in
            let id = UUID()
            let timeoutTask = Task { [weak self] in
                guard timeout > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                var awaiter: ReadyAwaiter?
                var elapsed: TimeInterval = 0
                stateQueue.sync {
                    guard self.lastReadyDetail == nil,
                          let index = self.readyAwaiters.firstIndex(where: { $0.id == id })
                    else { return }

                    elapsed = Date().timeIntervalSince(start)
                    awaiter = self.readyAwaiters.remove(at: index)
                }
                guard let awaiter else { return }
                awaiter.timeoutTask.cancel()
                awaiter.continuation.resume(returning: .timedOut(elapsed: elapsed))
            }
            stateQueue.sync {
                readyAwaiters.append(ReadyAwaiter(id: id, continuation: continuation, timeoutTask: timeoutTask))
            }
        }
    }

    func publish(data: Data, options: DataPublishOptions) async throws {
        guard let room else {
            throw ConnectionManagerError.roomUnavailable
        }
        do {
            try await room.localParticipant.publish(data: data, options: options)
        } catch {
            errorHandler(error)
            throw error
        }
    }

    /// Establish a LiveKit connection.
    ///
    /// - Parameters:
    ///   - details: Token‑service credentials (URL + participant token).
    ///   - enableMic: Whether to enable the local microphone immediately.
    ///   - throwOnMicrophoneFailure: If true, throws error when microphone setup fails. If false, logs warning and continues.
    ///   - graceTimeout: Fallback (in seconds) before we assume the agent is
    ///     ready even if no audio‑track subscription event is observed.
    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool = true,
        networkConfiguration: LiveKitNetworkConfiguration,
        graceTimeout: TimeInterval = 0.5 // Reduced to 500ms based on test results showing consistent timeouts
    ) async throws {
        resolveReadyAwaiters(with: .timedOut(elapsed: 0))
        readyStartTime = Date()
        lastReadyDetail = nil

        let room = Room()
        self.room = room

        let connectOptions = await networkConfiguration.makeConnectOptions()

        // Delegate encapsulates all readiness logic.
        let rd = await ReadyDelegate(
            graceTimeout: graceTimeout,
            logger: logger,
            onReady: { [weak self] source in
                self?.logger.debug("Ready delegate fired onReady callback", context: ["source": "\(source)"])
                self?.handleAgentReady(source: source)
            },
            onDisconnected: { [weak self] in
                self?.onAgentDisconnected?()
            }
        )
        readyDelegate = rd
        room.add(delegate: rd)

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
            errorHandler(error)
            if await LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission() {
                errorHandler(ConversationError.localNetworkPermissionRequired)
            }
            throw error
        }

        if enableMic {
            // Await microphone enabling to ensure it's ready before proceeding
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                logger.info("Microphone enabled successfully")
            } catch {
                logger.error("Failed to enable microphone", context: ["error": "\(error)"])

                if throwOnMicrophoneFailure {
                    errorHandler(error)
                    throw ConversationError.microphoneToggleFailed(error)
                } else {
                    logger.warning("Continuing without microphone due to error handling policy")
                    errorHandler(error)
                }
            }
        }
    }

    /// Disconnect and tear down.
    func disconnect() async {
        await room?.disconnect()
        room = nil
        readyDelegate = nil
        resolveReadyAwaitersOnTimeout()
        readyStartTime = nil
        lastReadyDetail = nil
    }

    /// Convenience helper returning a typed `AsyncStream` for incoming
    /// data‑channel messages.
    func dataEventsStream() -> AsyncStream<Data> {
        guard let room else { return AsyncStream { $0.finish() } }

        return AsyncStream { continuation in
            let delegate = DataChannelDelegate(continuation: continuation, logger: logger)
            room.add(delegate: delegate)

            continuation.onTermination = { @Sendable [weak room, weak delegate] _ in
                // Clean up the delegate when stream terminates
                guard let room, let delegate else { return }
                Task { @MainActor in
                    room.remove(delegate: delegate)
                }
            }
        }
    }
}

// MARK: – Ready‑detection delegate

extension ConnectionManager {
    /// Internal delegate that guards the *agent‑ready* handshake.
    @MainActor
    fileprivate final class ReadyDelegate: RoomDelegate {
        // MARK: – FSM

        private enum Stage { case idle, waitingForSubscription, ready }

        private var stage: Stage = .idle
        private var timeoutTask: Task<Void, Never>?

        enum ReadySource: CustomStringConvertible, Sendable {
            case trackSubscribed
            case graceTimeout

            var description: String {
                switch self {
                case .trackSubscribed: "trackSubscribed"
                case .graceTimeout: "graceTimeout"
                }
            }
        }

        // MARK: – Timing

        private let graceTimeout: TimeInterval
        private let logger: any Logging

        // MARK: – Callbacks

        private let onReady: @MainActor @Sendable (ReadySource) -> Void
        private let onDisconnected: @MainActor @Sendable () -> Void

        // MARK: – Init

        init(
            graceTimeout: TimeInterval,
            logger: any Logging,
            onReady: @escaping @MainActor @Sendable (ReadySource) -> Void,
            onDisconnected: @escaping @MainActor @Sendable () -> Void
        ) {
            self.graceTimeout = graceTimeout
            self.logger = logger
            self.onReady = onReady
            self.onDisconnected = onDisconnected
        }

        // MARK: – RoomDelegate

        nonisolated func roomDidConnect(_ room: Room) {
            Task {
                await self.handleRoomDidConnect(room: room)
            }
        }

        private func handleRoomDidConnect(room: Room) {
            guard stage == .idle else { return }

            // Check if we can go ready immediately (fast path)
            var foundReadyAgent = false
            for participant in room.remoteParticipants.values {
                if hasSubscribedAudioTrack(participant) {
                    markReady(source: .trackSubscribed)
                    foundReadyAgent = true
                    break
                }
            }

            if !foundReadyAgent {
                stage = .waitingForSubscription
                startTimeout()
            }
        }

        nonisolated func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
            Task {
                await self.handleParticipantDidConnect(room: room)
            }
        }

        private func handleParticipantDidConnect(room: Room) {
            if stage == .idle {
                stage = .waitingForSubscription
                startTimeout()
            } else if stage != .waitingForSubscription {
                return
            }

            evaluateExistingSubscriptions(in: room)
        }

        nonisolated func room(
            _: Room,
            participant _: RemoteParticipant,
            didSubscribeTrack publication: RemoteTrackPublication
        ) {
            Task {
                await self.handleDidSubscribeTrack(publication: publication)
            }
        }

        private func handleDidSubscribeTrack(publication: RemoteTrackPublication) {
            guard stage == .waitingForSubscription else { return }

            if publication.kind == .audio {
                logger.debug("Audio track subscribed - marking ready!")
                markReady(source: .trackSubscribed)
            }
        }

        nonisolated func room(
            _ room: Room,
            participantDidDisconnect participant: RemoteParticipant
        ) {
            let identityString = participant.identity.map { String(describing: $0) } ?? ""
            // Capture needed logic before Task to be safe, though participant is reference type so strict concurrency might warn.
            // String creation is safe.
            Task {
                await self.handleParticipantDidDisconnect(room: room, identityString: identityString)
            }
        }

        func handleParticipantDidDisconnect(room: Room, identityString: String) {
            let isAgent = identityString.hasPrefix("agent")

            if isAgent || room.remoteParticipants.isEmpty {
                reset()
                onDisconnected()
            }
        }

        nonisolated func room(_: Room, didUpdateConnectionState _: ConnectionState, from _: ConnectionState) { /* unused */ }

        // MARK: – Private helpers

        private func evaluateExistingSubscriptions(in room: Room) {
            for participant in room.remoteParticipants.values {
                if hasSubscribedAudioTrack(participant) {
                    logger.debug("Found existing subscribed audio track!")
                    markReady(source: .trackSubscribed)
                    return
                }
            }
            logger.debug("No subscribed audio tracks found yet, waiting...")
        }

        private func hasSubscribedAudioTrack(_ participant: RemoteParticipant) -> Bool {
            participant.audioTracks.contains { publication in
                publication.isSubscribed && publication.track != nil
            }
        }

        private func markReady(source: ReadySource) {
            guard stage != .ready else { return }
            stage = .ready
            cancelTimeout()
            onReady(source)
        }

        private func startTimeout() {
            logger.debug("Starting grace timeout", context: ["seconds": "\(graceTimeout)"])

            // Cancel previous if any (though shouldn't happen in valid flow)
            timeoutTask?.cancel()

            timeoutTask = Task<Void, Never> { [weak self, graceTimeout] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(graceTimeout * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    handleTimeout()
                } catch {
                    // Task was cancelled or failed, exit gracefully without throwing
                    return
                }
            }
        }

        private func handleTimeout() {
            if stage == .waitingForSubscription {
                logger.warning("Grace timeout reached! Marking ready anyway.")
                markReady(source: .graceTimeout)
            }
        }

        private func cancelTimeout() {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        func reset() {
            cancelTimeout()
            stage = .idle
        }
    }
}

// MARK: – Data‑channel delegate

/// Thread-safe delegate for handling data channel events.
/// Uses an actor to safely manage the AsyncStream continuation without @unchecked Sendable.
private actor DataChannelActor {
    private let continuation: AsyncStream<Data>.Continuation
    private let logger: any Logging

    init(continuation: AsyncStream<Data>.Continuation, logger: any Logging) {
        self.continuation = continuation
        self.logger = logger
    }

    func handleData(_ data: Data, from participant: RemoteParticipant?) {
        guard participant != nil else {
            logger.warning("Received data but no participant, ignoring")
            return
        }
        continuation.yield(data)
    }

    func handleConnectionStateChange(_ connectionState: ConnectionState) {
        if connectionState == .disconnected {
            continuation.finish()
        }
    }

    func handleParticipantConnected(identity: String) {
        logger.debug("Remote participant connected", context: ["identity": identity])
    }

    func handleParticipantDisconnected(identity: String) {
        logger.debug("Remote participant disconnected", context: ["identity": identity])
    }
}

private final class DataChannelDelegate: RoomDelegate {
    private let actor: DataChannelActor

    init(continuation: AsyncStream<Data>.Continuation, logger: any Logging) {
        actor = DataChannelActor(continuation: continuation, logger: logger)
    }

    // MARK: – Delegate

    nonisolated func room(
        _: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic _: String,
        encryptionType _: EncryptionType
    ) {
        Task {
            await actor.handleData(data, from: participant)
        }
    }

    nonisolated func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from _: ConnectionState) {
        Task {
            await actor.handleConnectionStateChange(connectionState)
        }
    }

    nonisolated func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity != nil ? String(describing: participant.identity!) : "unknown"
        Task {
            await actor.handleParticipantConnected(identity: identity)
        }
    }

    nonisolated func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity != nil ? String(describing: participant.identity!) : "unknown"
        Task {
            await actor.handleParticipantDisconnected(identity: identity)
        }
    }
}

// swiftlint:enable file_length

// MARK: – Convenience error extension

extension ConversationError {
    static let notImplemented = ConversationError.authenticationFailed("Not implemented yet")
}
