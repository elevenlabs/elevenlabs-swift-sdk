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

    private(set) var logger: any Logging
    private(set) var tokenService: any TokenServicing
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    private init(configuration: ElevenLabs.Configuration = .default) {
        logger = SDKLogger(logLevel: configuration.logLevel)
        tokenService = Self.makeTokenService(configuration: configuration)
        webRTCConnectionManager = WebRTCConnectionManager(logger: logger)
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger)
    }

    func update(configuration: ElevenLabs.Configuration) {
        logger = SDKLogger(logLevel: configuration.logLevel)
        tokenService = Self.makeTokenService(configuration: configuration)
    }

    private static func makeTokenService(configuration: ElevenLabs.Configuration) -> any TokenServicing {
        TokenService(configuration: TokenService.Configuration(
            apiEndpoint: configuration.apiEndpoint?.absoluteString,
            websocketURL: configuration.websocketUrl
        ))
    }
}
