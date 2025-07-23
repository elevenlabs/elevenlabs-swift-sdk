import Foundation
import LiveKit

/// Connection manager for LiveKit room connections
@MainActor
class ConnectionManager {
    private var _room: Room?

    var room: Room? { _room }

    func connect(details: TokenService.ConnectionDetails, enableMic: Bool) async throws {
        let room = Room()
        _room = room

        try await room.connect(url: details.serverUrl, token: details.participantToken)

        if enableMic {
            // Enable microphone
            try await room.localParticipant.setMicrophone(enabled: true)
        }
    }

    func disconnect() async {
        await _room?.disconnect()
        _room = nil
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

    func room(_: Room, didUpdate _: ConnectionState, from _: ConnectionState) {
        // Connection state changed
    }

    func roomDidConnect(_: Room) {
        // Room connected successfully
    }

    func room(_: Room, didDisconnectWithError _: Error?) {
        continuation.finish()
    }

    // Additional delegate methods to catch all possible events
    func room(_: Room, participant _: RemoteParticipant, didJoin _: ()) {
        // Remote participant joined
    }

    func room(_: Room, participant _: RemoteParticipant, didLeave _: ()) {
        // Remote participant left
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
