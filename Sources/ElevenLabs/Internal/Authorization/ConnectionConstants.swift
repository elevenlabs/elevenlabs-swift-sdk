import Foundation

enum ConnectionConstants {
    /// LiveKit signaling endpoint used for voice conversations.
    static let voiceConversationUrl = "wss://livekit.rtc.elevenlabs.io"
    /// WebSocket endpoint used for text-only conversations.
    static let textConversationUrl = "wss://api.elevenlabs.io/v1/convai/conversation"
    static let tokenUrl = "https://api.elevenlabs.io/v1/convai/conversation/token"
}
