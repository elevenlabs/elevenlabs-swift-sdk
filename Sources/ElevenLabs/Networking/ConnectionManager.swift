import Foundation
import LiveKit

/// Connection manager for LiveKit room connections
@MainActor
class ConnectionManager {
    private var _room: Room?

    private var readyDelegate: ReadyDelegate?

    var onAgentReady: (() -> Void)?
    var onAgentDisconnected: (() -> Void)?

    var room: Room? { _room }

    func connect(details: TokenService.ConnectionDetails, enableMic: Bool) async throws {
        let room = Room()
        _room = room

        let rd = ReadyDelegate(
            onReady: { [weak self] in
                self?.onAgentReady?()
            },
            onDisconnected: { [weak self] in self?.onAgentDisconnected?() }
        )
        readyDelegate = rd // Keep strong reference
        room.add(delegate: rd)

        // Note: DataChannelDelegate removed - now using DataChannelReceiver from Dependencies
        try await room.connect(url: details.serverUrl, token: details.participantToken)

        if enableMic {
            // Enable microphone
            try await room.localParticipant.setMicrophone(enabled: true)
        }
    }

    func disconnect() async {
        await _room?.disconnect()
        _room = nil
        readyDelegate = nil // Clean up delegate reference
    }

    func dataEventsStream() -> AsyncStream<Data> {
        guard let room = _room else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            room.add(delegate: DataChannelDelegate(continuation: continuation))

            continuation.onTermination = { _ in
                // Stream terminated
            }
        }
    }

    /// Enhanced delegate: waits for agent track subscription before triggering ready.
    private final class ReadyDelegate: RoomDelegate, @unchecked Sendable {
        private var agentConnected = false
        private var agentTrackSubscribed = false
        private var timeoutTask: Task<Void, Never>?
        private let onReady: () -> Void
        private let onDisconnected: () -> Void
        private let timeoutDuration: TimeInterval = 10.0 // 10 second timeout

        init(onReady: @escaping () -> Void, onDisconnected: @escaping () -> Void) {
            self.onReady = onReady
            self.onDisconnected = onDisconnected
        }

        func room(_: Room, participantDidConnect _: RemoteParticipant) {
            let timestamp = Date()
            guard !agentConnected else {
                return
            }

            // Only mark as connected, don't call onReady yet
            agentConnected = true
            startTimeoutTimer()
            checkAgentReady()
        }

        func room(_ room: Room, participantDidDisconnect _: RemoteParticipant) {
            if agentConnected, room.remoteParticipants.isEmpty {
                print("[ConnectionManager] All participants disconnected, resetting agent state")
                cancelTimeoutTimer()
                agentConnected = false
                agentTrackSubscribed = false
                onDisconnected()
            }
        }

        func roomDidConnect(_ room: Room) {
            let timestamp = Date()

            // Check if agent is already in the room
            if !agentConnected, !room.remoteParticipants.isEmpty {
                for (_, participant) in room.remoteParticipants {
                    // Check if agent already has tracks published
                    if !participant.audioTracks.isEmpty {
                        agentTrackSubscribed = true
                    }
                }
                agentConnected = true
                startTimeoutTimer()
                checkAgentReady()
            } else {
                print("[ConnectionManager] No agent in room yet, waiting for participantDidConnect")
            }
        }

        func room(_: Room, participant _: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
            print("[ConnectionManager] Agent audio track subscribed, checking readiness... \(publication.kind) \(agentConnected) \(agentTrackSubscribed)")
            // Only trigger for agent audio tracks
            if publication.kind == .audio, agentConnected {
                agentTrackSubscribed = true
                print("[ConnectionManager] Agent audio track subscribed, checking readiness...")
                checkAgentReady()
            } else {
                print("[ConnectionManager] Track ignored - not agent audio or already processed")
            }
        }

        private func checkAgentReady() {
            if agentConnected, agentTrackSubscribed {
                cancelTimeoutTimer()
                onReady()
            } else {
                print("[ConnectionManager] Agent not fully ready yet, waiting...")
            }
        }

        private func startTimeoutTimer() {
            cancelTimeoutTimer()
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutDuration * 1_000_000_000))
                if !Task.isCancelled && agentConnected && !agentTrackSubscribed {
                    print("[ConnectionManager] Timeout waiting for agent track - connection failed")
                    // Reset state and trigger disconnection
                    agentConnected = false
                    agentTrackSubscribed = false
                    onDisconnected()
                }
            }
        }

        private func cancelTimeoutTimer() {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        func room(_: Room, didUpdate _: ConnectionState, from _: ConnectionState) {}
    }
}

// MARK: - Data Channel Delegate

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
        print("DataChannelDelegate: Room connected successfully")
        print("DataChannelDelegate: Remote participants count: \(room.remoteParticipants.count)")
    }

    func room(_: Room, didDisconnectWithError _: Error?) {
        continuation.finish()
    }

    // Additional delegate methods to catch all possible events
    func room(_ room: Room, participant: RemoteParticipant, didJoin _: ()) {
        print("DataChannelDelegate: Remote participant joined - \(participant.identity)")
        print("DataChannelDelegate: Total remote participants: \(room.remoteParticipants.count)")
    }

    func room(_ room: Room, participant: RemoteParticipant, didLeave _: ()) {
        print("DataChannelDelegate: Remote participant left - \(participant.identity)")
        print("DataChannelDelegate: Total remote participants: \(room.remoteParticipants.count)")
    }

    func room(_: Room, participant _: RemoteParticipant, didPublishTrack _: RemoteTrackPublication) {
        // Remote participant published track
    }

    func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack _: RemoteTrackPublication) {
        // Remote participant unpublished track
    }

    func room(_: Room, participant _: LocalParticipant, didPublish _: LocalTrackPublication) {
        // Local participant published track
    }

    func room(_: Room, participant _: LocalParticipant, didUnpublish _: LocalTrackPublication) {
        // Local participant unpublished track
    }
}

extension ConversationError {
    static let notImplemented = ConversationError.authenticationFailed("Not implemented yet")
}
