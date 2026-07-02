import Foundation

@MainActor
protocol ConversationDependencyProvider: AnyObject {
    var tokenService: any TokenServicing { get async }
    var logger: any Logging { get }
    var errorHandler: ((Swift.Error?) -> Void)? { get }

    func webRTCConnectionManager() async -> any WebRTCConnectionManaging
    func webSocketConnectionManager() async -> any WebSocketConnectionManaging
}

/// A minimalistic dependency injection container for internal SDK use.
/// Since all SDK operations run on MainActor, this uses simple lazy initialization
/// without additional synchronization overhead.
///
/// - Note: For production apps, consider using a more flexible approach offered by e.g.:
///   - [Factory](https://github.com/hmlongco/Factory)
///   - [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
///   - [Needle](https://github.com/uber/needle)
@MainActor
final class Dependencies: ConversationDependencyProvider {
    static let shared = Dependencies()

    private init() {}

    // MARK: Services

    private var _tokenService: (any TokenServicing)?
    var tokenService: any TokenServicing {
        get async {
            if let existing = _tokenService {
                return existing
            }
            let globalConfig = ElevenLabs.Global.shared.configuration
            let tokenServiceConfig = TokenService.Configuration(
                apiEndpoint: globalConfig.apiEndpoint?.absoluteString,
                websocketURL: globalConfig.websocketUrl
            )
            let service = TokenService(configuration: tokenServiceConfig)
            _tokenService = service
            return service
        }
    }

    private var _webRTCConnectionManager: (any WebRTCConnectionManaging)?
    private var _webSocketConnectionManager: (any WebSocketConnectionManaging)?

    func webRTCConnectionManager() async -> any WebRTCConnectionManaging {
        if let existing = _webRTCConnectionManager {
            return existing
        }
        let service = await tokenService
        let manager = WebRTCConnectionManager(logger: logger, tokenService: service)
        _webRTCConnectionManager = manager
        return manager
    }

    func webSocketConnectionManager() async -> any WebSocketConnectionManaging {
        if let existing = _webSocketConnectionManager {
            return existing
        }
        let transport = WebSocketConnectionManager(logger: logger)
        _webSocketConnectionManager = transport
        return transport
    }

    var logger: any Logging {
        SDKLogger(logLevel: .warning)
    }

    var errorHandler: ((Swift.Error?) -> Void)? {
        nil
    }
}
