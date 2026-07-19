import Foundation

// Main namespace & entry point for the ElevenLabs Conversational AI SDK.
//
// ```swift
// // Start a conversation directly - simple and clean
// let client = ConversationClient()
// let result = try await client.startConversation(
//     agentId: "agent_123",
//     config: .init(conversationOverrides: .init(textOnly: false))
// )
//
// // Send a message
// try await client.sendMessage("Hello!")
//
// // End the conversation
// await client.endConversation()
// ```

public enum ElevenLabs {
    // MARK: - Version

    public static let version = "3.2.2"

    // MARK: - Configuration

    /// Global, optional SDK configuration. Provide once at app start.
    /// If you never call `configure(_:)`, sensible defaults are used.
    @MainActor
    public static func configure(_ configuration: Configuration) {
        Global.shared.configuration = configuration
    }

    // Language enum is already public and accessible as ElevenLabs.Language

    // MARK: - Internal Global State

    /// Internal container for global (process-wide) configuration.
    /// This mimics the old `Dependencies` singleton but keeps it internal.
    @MainActor
    final class Global {
        static let shared = Global()
        var configuration: Configuration = .default
        private init() {}
    }
}
