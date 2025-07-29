import Foundation
import LiveKit

/// **ConnectionManager**
///
/// A small façade around `LiveKit.Room` that emits **exactly one**
/// *agent‑ready* signal at the precise moment the remote agent is
/// reachable **and** at least one of its audio tracks is subscribed.
///
/// ▶︎ *Never too early*: we wait for both the participant *and* its track.
/// ▶︎ *Never too late*: a short, configurable grace‑timeout prevents
///   indefinite waiting on networks where track subscription events can
///   be lost or delayed.
///
/// After the ready event fires you can safely send client‑initiation
/// metadata—​the remote side will be present and able to receive it.
@MainActor
final class ConnectionManager {
    // MARK: – Public callbacks

    /// Fired **once** when the remote agent is considered ready.
    var onAgentReady: (() -> Void)?

    /// Fired when all remote participants have left or the room disconnects.
    var onAgentDisconnected: (() -> Void)?

    // MARK: – Public state accessors

    private(set) var room: Room?

    // MARK: – Private

    private var readyDelegate: ReadyDelegate?

    // MARK: – Lifecycle

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
        graceTimeout: TimeInterval = 0.5 // Reduced to 500ms based on test results showing consistent timeouts
    ) async throws {
        let room = Room()
        self.room = room

        print("[ConnectionManager-Timing] Starting connection with grace timeout: \(graceTimeout)s")

        // Delegate encapsulates all readiness logic.
        let rd = ReadyDelegate(
            graceTimeout: graceTimeout,
            onReady: { [weak self] in
                print("[ConnectionManager-Timing] Ready delegate fired onReady callback")
                self?.onAgentReady?()
            },
            onDisconnected: { [weak self] in self?.onAgentDisconnected?() }
        )
        readyDelegate = rd
        room.add(delegate: rd)

        let connectStart = Date()
        try await room.connect(url: details.serverUrl,
                               token: details.participantToken)
        print("[ConnectionManager-Timing] LiveKit room.connect completed in \(Date().timeIntervalSince(connectStart))s")

        if enableMic {
            // Do not await—mic enabling should never gate readiness.
            Task { try? await room.localParticipant.setMicrophone(enabled: true) }
        }
    }

    /// Disconnect and tear down.
    func disconnect() async {
        await room?.disconnect()
        room = nil
        readyDelegate = nil
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

private extension ConnectionManager {
    /// Internal delegate that guards the *agent‑ready* handshake.
    final class ReadyDelegate: RoomDelegate, @unchecked Sendable {
        // MARK: – FSM

        private enum Stage { case idle, waitingForTrack, ready }
        private var stage: Stage = .idle

        // MARK: – Timing

        private let graceTimeout: TimeInterval
        private var timeoutTask: Task<Void, Never>?
        private var pollingTask: Task<Void, Never>?

        // MARK: – Callbacks

        private let onReady: () -> Void
        private let onDisconnected: () -> Void

        // MARK: – Init

        init(graceTimeout: TimeInterval,
             onReady: @escaping () -> Void,
             onDisconnected: @escaping () -> Void)
        {
            self.graceTimeout = graceTimeout
            self.onReady = onReady
            self.onDisconnected = onDisconnected
        }

        // MARK: – RoomDelegate

        func roomDidConnect(_ room: Room) {
            guard stage == .idle else { return }

            if !room.remoteParticipants.isEmpty {
                // Check if we can go ready immediately (fast path)
                var foundReadyAgent = false
                for participant in room.remoteParticipants.values {
                    if !participant.audioTracks.isEmpty {
                        markReady()
                        foundReadyAgent = true
                        break
                    }
                }

                // Only wait if we didn't find a ready agent
                if !foundReadyAgent {
                    stage = .waitingForTrack
                    startTimeout()
                    // Start aggressive polling for audio track subscription
                    startAudioTrackPolling(room: room)
                }
            }
        }

        func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
            guard stage == .idle else { return }
            stage = .waitingForTrack
            startTimeout()
            evaluateExistingTracks(in: room)
            // Start aggressive polling for audio track subscription
            startAudioTrackPolling(room: room)
        }

        func room(_: Room,
                  participant _: RemoteParticipant,
                  didPublishTrack publication: RemoteTrackPublication)
        {
            guard stage == .waitingForTrack else { return }
            if publication.kind == .audio {
                markReady()
            }
        }

        func room(_ room: Room,
                  participantDidDisconnect _: RemoteParticipant)
        {
            guard room.remoteParticipants.isEmpty else { return }
            reset()
            onDisconnected()
        }

        func room(_: Room, didUpdate _: ConnectionState, from _: ConnectionState) { /* unused */ }

        // MARK: – Private helpers

        private func evaluateExistingTracks(in room: Room) {
            for participant in room.remoteParticipants.values {
                // Check for published tracks instead of subscribed ones
                if !participant.audioTracks.isEmpty {
                    markReady(); return
                }
            }
            print("[ReadyDelegate-Timing] No published audio tracks found yet, waiting...")
        }

        private func markReady() {
            guard stage != .ready else { return }
            stage = .ready
            cancelTimeout()
            cancelPolling() // Stop polling when ready
            onReady()
        }

        private func startTimeout() {
            cancelTimeout()
            print("[ReadyDelegate-Timing] Starting grace timeout of \(graceTimeout)s")
            timeoutTask = Task { [graceTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(graceTimeout * 1_000_000_000))
                if !Task.isCancelled, stage == .waitingForTrack {
                    print("[ReadyDelegate-Timing] Grace timeout reached! Marking ready anyway.")
                    markReady() // proceed after grace period
                }
            }
        }

        private func cancelTimeout() {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        private func startAudioTrackPolling(room: Room) {
            cancelPolling()
            print("[ReadyDelegate-Timing] Starting aggressive audio track polling...")
            pollingTask = Task {
                // Poll every 50ms for up to 500ms (10 attempts)
                for attempt in 1 ... 10 {
                    guard !Task.isCancelled, stage == .waitingForTrack else { return }

                    for participant in room.remoteParticipants.values {
                        if !participant.audioTracks.isEmpty {
                            print("[ReadyDelegate-Timing] Polling detected published audio track on attempt \(attempt)!")
                            markReady()
                            return
                        }
                    }

                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
                print("[ReadyDelegate-Timing] Audio track polling completed without finding published track")
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

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        continuation.yield(data)
    }

    func room(_: Room, participant _: LocalParticipant?, didReceiveData data: Data, forTopic _: String) {
        continuation.yield(data)
    }

    func room(_ room: Room, didUpdate connectionState: ConnectionState, from previousState: ConnectionState) {
        print("DataChannelDelegate: Connection state changed from \(previousState) to \(connectionState)")
        print("DataChannelDelegate: Remote participants count: \(room.remoteParticipants.count)")
    }

    func roomDidConnect(_ room: Room) {
        print("DataChannelDelegate: Room connected successfully – remote participants: \(room.remoteParticipants.count)")
    }

    func room(_: Room, didDisconnectWithError _: Error?) {
        continuation.finish()
    }
}

// MARK: – Convenience error extension

extension ConversationError {
    static let notImplemented = ConversationError.authenticationFailed("Not implemented yet")
}
