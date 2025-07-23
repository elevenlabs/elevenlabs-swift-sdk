import Foundation
import LiveKit

// MARK: - LiveKit Extensions for ElevenLabs Agent Support

extension Room {
    /// The first remote participant that represents an ElevenLabs agent
    /// ElevenLabs agents join as remote participants in the LiveKit room
    var agentParticipant: RemoteParticipant? {
        // In ElevenLabs conversations, typically there's only one remote participant (the agent)
        // Return the first remote participant, which should be the agent
        return remoteParticipants.values.first
    }
}
