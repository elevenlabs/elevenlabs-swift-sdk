import Foundation

@MainActor
protocol ConversationDependencyProvider: AnyObject {
    var tokenService: any TokenServicing { get }
    var logger: any Logging { get }
    var webRTCConnectionManager: any WebRTCConnectionManaging { get }
    var webSocketConnectionManager: any WebSocketConnectionManaging { get }
}

/// A minimalistic dependency injection container for internal SDK use.
///
/// - Note: For production apps, consider using a more flexible approach offered by e.g.:
///   - [Factory](https://github.com/hmlongco/Factory)
///   - [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
///   - [Needle](https://github.com/uber/needle)
@MainActor
final class Dependencies: ConversationDependencyProvider {
    static let shared = Dependencies()

    let logger: any Logging
    let tokenService: any TokenServicing
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    private init() {
        let globalConfig = ElevenLabs.Global.shared.configuration
        logger = SDKLogger(logLevel: globalConfig.logLevel)
        tokenService = TokenService(configuration: TokenService.Configuration(
            apiEndpoint: globalConfig.apiEndpoint?.absoluteString,
            websocketURL: globalConfig.websocketUrl
        ))
        webRTCConnectionManager = WebRTCConnectionManager(logger: logger)
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger)
    }
}
