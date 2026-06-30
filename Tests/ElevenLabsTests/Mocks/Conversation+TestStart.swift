@testable import ElevenLabs

@MainActor
extension Conversation {
    /// Test convenience mirroring the pre-redesign instance entry point. Config
    /// is fixed at construction now; pass non-default config to `Conversation(...)`.
    func startConversation(auth: ConversationAuth, config _: ConversationConfig = .default) async throws {
        try await connect(auth: auth)
    }
}
