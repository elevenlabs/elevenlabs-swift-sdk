import Foundation

@MainActor
protocol ConversationDependencyProvider: AnyObject {
    var logger: any Logging { get }
    var webRTCConnectionManager: any WebRTCConnectionManaging { get }
    var webSocketConnectionManager: any WebSocketConnectionManaging { get }
}

/// A minimalistic dependency container for internal SDK use.
@MainActor
final class Dependencies: ConversationDependencyProvider {
    let logger: any Logging
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    init(endpoints: Endpoints = .production) {
        let globalConfig = ElevenLabs.Global.shared.configuration
        let logger = SDKLogger(logLevel: globalConfig.logLevel)
        self.logger = logger
        webRTCConnectionManager = WebRTCConnectionManager(
            logger: logger,
            tokenService: TokenService(endpoints: endpoints),
            endpoints: endpoints
        )
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger, endpoints: endpoints)
    }
}
