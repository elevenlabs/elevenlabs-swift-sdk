@testable import ElevenLabs

@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    let logger: any Logging
    let tokenService: any TokenServicing
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    init(
        tokenService: any TokenServicing,
        webRTCConnectionManager: any WebRTCConnectionManaging,
        webSocketConnectionManager: any WebSocketConnectionManaging = MockWebSocketConnectionManager()
    ) {
        self.tokenService = tokenService
        self.webRTCConnectionManager = webRTCConnectionManager
        self.webSocketConnectionManager = webSocketConnectionManager
        logger = SDKLogger(logLevel: .error)
    }
}
