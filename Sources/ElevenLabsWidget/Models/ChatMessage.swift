#if os(iOS)
import ElevenLabs
import Foundation

/// A transcript bubble, projected from the SDK's ``Message``.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, agent }

    let id: String
    let role: Role
    let content: String
    let timestamp: Date

    init(_ message: Message) {
        id = message.id
        role = message.role == .user ? .user : .agent
        content = message.content
        timestamp = message.timestamp
    }
}
#endif
