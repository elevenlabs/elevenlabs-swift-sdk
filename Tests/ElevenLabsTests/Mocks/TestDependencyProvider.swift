@testable import ElevenLabs

/// Test double for `ConversationDependencyProvider` that vends mock connection
/// managers, so the full `Conversation` startup pipeline can be exercised
/// without touching the network or LiveKit.
@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    let logger: any Logging
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    init(
        webRTCConnectionManager: (any WebRTCConnectionManaging)? = nil,
        webSocketConnectionManager: (any WebSocketConnectionManaging)? = nil
    ) {
        self.webRTCConnectionManager = webRTCConnectionManager ?? MockWebRTCConnectionManager()
        self.webSocketConnectionManager = webSocketConnectionManager ?? MockWebSocketConnectionManager()
        logger = SDKLogger(logLevel: .error)
    }
}
