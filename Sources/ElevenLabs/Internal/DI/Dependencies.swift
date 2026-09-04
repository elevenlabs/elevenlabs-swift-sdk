import Foundation

@MainActor
public protocol ConversationDependencyProvider: AnyObject {
    var webRTCConnectionManager: any WebRTCConnectionManaging { get }
    var webSocketConnectionManager: any WebSocketConnectionManaging { get }
}

/// A minimalistic dependency container for internal SDK use.
@MainActor
final class Dependencies: ConversationDependencyProvider {
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    init(logLevel: LogLevel = .warning, endpoints: Endpoints = .production) {
        let logger = SDKLogger(logLevel: logLevel)
        webRTCConnectionManager = WebRTCConnectionManager(
            logger: logger,
            tokenService: TokenService(endpoints: endpoints),
            endpoints: endpoints
        )
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger, endpoints: endpoints)
    }
}
