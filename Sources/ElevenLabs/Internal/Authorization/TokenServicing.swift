import Foundation

protocol TokenServicing: Sendable {
    /// Fetch a LiveKit room token for an ElevenLabs conversation.
    func fetchRoomToken(auth: ConversationAuth, apiBase: URL, environment: String?) async throws -> String
}
