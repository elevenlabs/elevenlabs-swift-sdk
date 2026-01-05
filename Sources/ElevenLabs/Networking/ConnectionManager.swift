import Foundation
import LiveKit

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
/// After the ready event fires you can safely send client‑initiation
/// metadata—​the remote side will be present and able to receive it.
@MainActor
final class ConnectionManager: ConnectionManaging {
    // MARK: – Public callbacks

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

    // MARK: – Lifecycle

    private func resolveReadyAwaiters(with result: AgentReadyWaitResult) {
        guard !readyAwaiters.isEmpty else { return }
        let awaiters = readyAwaiters
        readyAwaiters.removeAll()
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
        if lastReadyDetail == nil {
            lastReadyDetail = detail
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
                await MainActor.run {
                    guard let self else { return }
                    guard self.lastReadyDetail == nil,
                          let index = self.readyAwaiters.firstIndex(where: { $0.id == id })
                    else { return }

                    let elapsed = Date().timeIntervalSince(start)
                    let awaiter = self.readyAwaiters.remove(at: index)
                    awaiter.timeoutTask.cancel()
                    awaiter.continuation.resume(returning: .timedOut(elapsed: elapsed))
                }
            }

            readyAwaiters.append(ReadyAwaiter(id: id, continuation: continuation, timeoutTask: timeoutTask))
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
    ///   - graceTimeout: Fallback (in seconds) before we assume the agent is
    ///     ready even if no audio‑track subscription event is observed.
    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        networkConfiguration: LiveKitNetworkConfiguration,
        graceTimeout: TimeInterval = 0.5 // Reduced to 500ms based on test results showing consistent timeouts
    ) async throws {
        resolveReadyAwaiters(with: .timedOut(elapsed: 0))
        readyStartTime = Date()
        lastReadyDetail = nil

        let room = Room()
        self.room = room

        let connectOptions = networkConfiguration.makeConnectOptions()

        // Delegate encapsulates all readiness logic.
        let rd = ReadyDelegate(
            graceTimeout: graceTimeout,
            onReady: { [weak self] source in
                print("[ConnectionManager-Timing] Ready delegate fired onReady callback (source: \(source))")
                self?.handleAgentReady(source: source)
            },
            onDisconnected: { [weak self] in self?.onAgentDisconnected?() }
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
            print("[ConnectionManager-Timing] LiveKit room.connect completed in \(Date().timeIntervalSince(connectStart))s")
        } catch {
            print("[ConnectionManager-Timing] LiveKit room.connect failed with error: \(error)")
            errorHandler(error)
            if LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission() {
                errorHandler(ConversationError.localNetworkPermissionRequired)
            }
            throw error
        }

        if enableMic {
            // Await microphone enabling to ensure it's ready before proceeding
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                print("[ConnectionManager] Microphone enabled successfully")
            } catch {
                print("[ConnectionManager] Failed to enable microphone: \(error)")
                errorHandler(error)
                // Don't throw - microphone issues shouldn't prevent connection
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
            room.add(delegate: DataChannelDelegate(continuation: continuation))
            continuation.onTermination = { _ in /* no‑op */ }
        }
    }
}

// MARK: – Ready‑detection delegate

extension ConnectionManager {
    /// Internal delegate that guards the *agent‑ready* handshake.
    fileprivate final class ReadyDelegate: RoomDelegate, @unchecked Sendable {
        // MARK: – FSM

        private enum Stage { case idle, waitingForSubscription, ready }
        private var stage: Stage = .idle

        enum ReadySource: CustomStringConvertible {
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
        private var timeoutTask: Task<Void, Never>?
        private var pollingTask: Task<Void, Never>?

        // MARK: – Callbacks

        private let onReady: (ReadySource) -> Void
        private let onDisconnected: () -> Void

        // MARK: – Init

        init(
            graceTimeout: TimeInterval,
            onReady: @escaping (ReadySource) -> Void,
            onDisconnected: @escaping () -> Void
        ) {
            self.graceTimeout = graceTimeout
            self.onReady = onReady
            self.onDisconnected = onDisconnected
        }

        deinit {
            // Normally tasks are cancelled via `reset()` on agent disconnect.
            // `deinit` serves as a safety net when disconnect events aren’t delivered
            // (e.g., when a Conversation is deallocated). Ensures all tasks are cleaned up.
            print("[ReadyDelegate] Deinitializing - cleaning up tasks")
            cancelTimeout()
            cancelPolling()
        }

        // MARK: – RoomDelegate

        func roomDidConnect(_ room: Room) {
            guard stage == .idle else { return }

            if !room.remoteParticipants.isEmpty {
                // Check if we can go ready immediately (fast path)
                var foundReadyAgent = false
                for participant in room.remoteParticipants.values {
                    if hasSubscribedAudioTrack(participant) {
                        markReady(source: .trackSubscribed)
                        foundReadyAgent = true
                        break
                    }
                }

                // Only wait if we didn't find a ready agent
                if !foundReadyAgent {
                    stage = .waitingForSubscription
                    startTimeout()
                    // Start aggressive polling for audio track subscription
                    startAudioTrackSubscriptionPolling(room: room)
                }
            }
        }

        func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
            stage = .waitingForSubscription
            startTimeout()
            evaluateExistingSubscriptions(in: room)
            // Start aggressive polling for audio track subscription
            startAudioTrackSubscriptionPolling(room: room)
        }

        func room(
            _: Room,
            participant _: RemoteParticipant,
            didSubscribeTrack publication: RemoteTrackPublication
        ) {
            guard stage == .waitingForSubscription else { return }
            if publication.kind == .audio {
                print("[ReadyDelegate-Timing] Audio track subscribed - marking ready!")
                markReady(source: .trackSubscribed)
            }
        }

        func room(
            _ room: Room,
            participantDidDisconnect participant: RemoteParticipant
        ) {
            let identityString = participant.identity.map { String(describing: $0) } ?? ""
            let isAgent = identityString.hasPrefix("agent")
            guard isAgent || room.remoteParticipants.isEmpty else { return }
            reset()
            onDisconnected()
        }

        func room(_: Room, didUpdateConnectionState _: ConnectionState, from _: ConnectionState) { /* unused */ }

        // MARK: – Private helpers

        private func evaluateExistingSubscriptions(in room: Room) {
            for participant in room.remoteParticipants.values {
                // Check for subscribed tracks instead of published ones
                if hasSubscribedAudioTrack(participant) {
                    markReady(source: .trackSubscribed); return
                }
            }
            print("[ReadyDelegate-Timing] No subscribed audio tracks found yet, waiting...")
        }

        private func hasSubscribedAudioTrack(_ participant: RemoteParticipant) -> Bool {
            participant.audioTracks.contains { publication in
                publication.isSubscribed && publication.track != nil
            }
        }

        private func markReady(source: ReadySource) {
            print("[ReadyDelegate-Timing] Marking ready!")
            guard stage != .ready else { return }
            stage = .ready
            cancelTimeout()
            cancelPolling() // Stop polling when ready
            onReady(source)
        }

        private func startTimeout() {
            print("[ReadyDelegate-Timing] Starting grace timeout of \(graceTimeout)s")
            timeoutTask = Task { [graceTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(graceTimeout * 1_000_000_000))
                if !Task.isCancelled, stage == .waitingForSubscription {
                    print("[ReadyDelegate-Timing] Grace timeout reached! Marking ready anyway.")
                    markReady(source: .graceTimeout) // proceed after grace period
                }
            }
        }

        private func cancelTimeout() {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        private func startAudioTrackSubscriptionPolling(room: Room) {
            cancelPolling()
            print("[ReadyDelegate-Timing] Starting aggressive audio track subscription polling...")
            pollingTask = Task {
                // Poll every 50ms for up to 500ms (10 attempts)
                for attempt in 1 ... 10 {
                    guard !Task.isCancelled, stage == .waitingForSubscription else { return }

                    for participant in room.remoteParticipants.values {
                        if hasSubscribedAudioTrack(participant) {
                            print("[ReadyDelegate-Timing] Polling detected subscribed audio track on attempt \(attempt)!")
                            markReady(source: .trackSubscribed)
                            return
                        }
                    }

                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
                print("[ReadyDelegate-Timing] Audio track subscription polling completed without finding subscribed track")
            }
        }

        private func cancelPolling() {
            pollingTask?.cancel()
            pollingTask = nil
        }

        private func reset() {
            cancelTimeout()
            cancelPolling()
            stage = .idle
        }
    }
}

// MARK: – Data‑channel delegate

private final class DataChannelDelegate: RoomDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    // MARK: – Delegate

    nonisolated func room(
        _: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic _: String,
        encryptionType _: EncryptionType
    ) {
        // Only process messages from the agent
        guard participant != nil else {
            print("[DataChannelReceiver] Received data but no participant, ignoring")
            return
        }

        continuation.yield(data)
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from previousState: ConnectionState) {
        print("DataChannelDelegate: Connection state changed from \(previousState) to \(connectionState)")
        print("DataChannelDelegate: Remote participants count: \(room.remoteParticipants.count)")

        if connectionState == .disconnected {
            continuation.finish()
        }
    }

    nonisolated func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        print("DataChannelDelegate: Remote participant \(String(describing: participant.identity)) connected")
    }

    nonisolated func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("DataChannelDelegate: Remote participant \(String(describing: participant.identity)) disconnected")
    }
}

// MARK: – Convenience error extension

extension ConversationError {
    static let notImplemented = ConversationError.authenticationFailed("Not implemented yet")
}
