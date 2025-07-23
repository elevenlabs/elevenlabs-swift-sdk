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
    
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String) {
        continuation.yield(data)
    }
    
    func room(_ room: Room, participant: LocalParticipant?, didReceiveData data: Data, forTopic topic: String) {
        continuation.yield(data)
    }
    
    func room(_ room: Room, didUpdate connectionState: ConnectionState, from oldValue: ConnectionState) {
        // Connection state changed
    }
    
    func roomDidConnect(_ room: Room) {
        // Room connected successfully
    }
    
    func room(_ room: Room, didDisconnectWithError error: Error?) {
        continuation.finish()
    }
    
    // Additional delegate methods to catch all possible events
    func room(_ room: Room, participant: RemoteParticipant, didJoin: ()) {
        // Remote participant joined
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didLeave: ()) {
        // Remote participant left
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        // Remote participant published track
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        // Remote participant unpublished track
    }
    
    func room(_ room: Room, participant: LocalParticipant, didPublish publication: LocalTrackPublication) {
        // Local participant published track
    }
    
    func room(_ room: Room, participant: LocalParticipant, didUnpublish publication: LocalTrackPublication) {
        // Local participant unpublished track
    }
}

extension ConversationError {
    static let notImplemented = ConversationError.authenticationFailed("Not implemented yet")
}
