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

    init() {
        let globalConfig = ElevenLabs.Global.shared.configuration
        let tokenService = TokenService(configuration: TokenService.Configuration(
            apiEndpoint: globalConfig.apiEndpoint?.absoluteString,
            websocketURL: globalConfig.websocketUrl
        ))
        let logger = SDKLogger(logLevel: globalConfig.logLevel)
        self.logger = logger
        webRTCConnectionManager = WebRTCConnectionManager(logger: logger, tokenService: tokenService)
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger)
    }
}
