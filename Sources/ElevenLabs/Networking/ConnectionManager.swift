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
            onReady: { [weak self] in self?.onAgentReady?() },
            onDisconnected: { [weak self] in self?.onAgentDisconnected?() }
        )
        readyDelegate = rd // Keep strong reference
        room.add(delegate: rd)

        let (_, continuation) = AsyncStream<Data>.makeStream()
        room.add(delegate: DataChannelDelegate(continuation: continuation))

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
            // Set up data received handler
            room.add(delegate: DataChannelDelegate(continuation: continuation))

            // Keep the stream alive
            continuation.onTermination = { _ in
                // Stream terminated
            }
        }
    }

    /// Minimal delegate: triggers once on `participantDidConnect` and handles disconnection.
    private final class ReadyDelegate: RoomDelegate, @unchecked Sendable {
        private var agentConnected = false
        private let onReady: () -> Void
        private let onDisconnected: () -> Void

        init(onReady: @escaping () -> Void, onDisconnected: @escaping () -> Void) {
            self.onReady = onReady
            self.onDisconnected = onDisconnected
        }

        func room(_: Room, participantDidConnect _: RemoteParticipant) {
            guard !agentConnected else {
                return
            }
            agentConnected = true
            onReady()
        }

        func room(_ room: Room, participantDidDisconnect _: RemoteParticipant) {
            if agentConnected, room.remoteParticipants.isEmpty {
                agentConnected = false
                onDisconnected()
            }
        }

        func roomDidConnect(_: Room) {}

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
