import Foundation
import LiveKit

protocol ConnectionManaging: AnyObject {
    var onAgentReady: (() -> Void)? { get set }
    var onAgentDisconnected: (() -> Void)? { get set }
    var room: Room? { get }
    var shouldObserveRoomConnection: Bool { get }
    var errorHandler: ((Swift.Error?) -> Void)? { get set }

    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool,
        networkConfiguration: LiveKitNetworkConfiguration,
        graceTimeout: TimeInterval
    ) async throws

    func disconnect() async
    func dataEventsStream() -> AsyncStream<Data>
    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult
    func publish(data: Data, options: DataPublishOptions) async throws
}

@MainActor
protocol ConversationDependencyProvider: AnyObject {
    var tokenService: any TokenServicing { get async }
    var logger: any Logging { get }
    var conversationStartup: any ConversationStartup { get async }
    var errorHandler: ((Swift.Error?) -> Void)? { get }

    func connectionManager() async -> any ConnectionManaging
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

    private var _connectionManager: (any ConnectionManaging)?

    func connectionManager() async -> any ConnectionManaging {
        if let existing = _connectionManager {
            return existing
        }
        let loggerInstance = logger
        let manager = ConnectionManager(logger: loggerInstance)
        _connectionManager = manager
        return manager
    }

    var logger: any Logging {
        SDKLogger(logLevel: .warning)
    }

    private var _conversationStartup: (any ConversationStartup)?
    var conversationStartup: any ConversationStartup {
        get async {
            if let existing = _conversationStartup {
                return existing
            }
            let loggerInstance = logger
            let startup = DefaultConversationStartup(logger: loggerInstance)
            _conversationStartup = startup
            return startup
        }
    }

    var errorHandler: ((Swift.Error?) -> Void)? {
        nil
    }
}
