import Foundation
import LiveKit

protocol TokenServicing: Sendable {
    func fetchConnectionDetails(configuration: ElevenLabsConfiguration) async throws -> TokenService.ConnectionDetails
}

@MainActor
protocol ConnectionManaging: AnyObject {
    var onAgentReady: (() -> Void)? { get set }
    var onAgentDisconnected: (() -> Void)? { get set }
    var room: Room? { get }
    var shouldObserveRoomConnection: Bool { get }
    var errorHandler: (Error?) -> Void { get set }

    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        graceTimeout: TimeInterval,
    ) async throws

    func disconnect() async
    func dataEventsStream() -> AsyncStream<Data>
    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult
    func publish(data: Data, options: DataPublishOptions) async throws
}

@MainActor
protocol ConversationDependencyProvider: AnyObject {
    var tokenService: any TokenServicing { get }
    var connectionManager: any ConnectionManaging { get }
    var errorHandler: (Error?) -> Void { get }
}

/// A minimalistic dependency injection container.
/// It allows sharing common dependencies e.g. `Room` between view models and services.
/// - Note: For production apps, consider using a more flexible approach offered by e.g.:
///   - [Factory](https://github.com/hmlongco/Factory)
///   - [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
///   - [Needle](https://github.com/uber/needle)
@MainActor
final class Dependencies: ConversationDependencyProvider {
    static let shared = Dependencies()

    private init() {}

    // MARK: LiveKit

    lazy var room = Room(roomOptions: RoomOptions(defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useBroadcastExtension: true)))

    // MARK: Services

    lazy var tokenService: any TokenServicing = {
        let globalConfig = ElevenLabs.Global.shared.configuration
        let tokenServiceConfig = TokenService.Configuration(
            apiEndpoint: globalConfig.apiEndpoint?.absoluteString,
            websocketURL: globalConfig.websocketUrl,
        )
        return TokenService(configuration: tokenServiceConfig)
    }()

    lazy var connectionManager: any ConnectionManaging = ConnectionManager()

    private lazy var localMessageSender = LocalMessageSender(room: room)

    lazy var messageSenders: [any MessageSender] = [
        localMessageSender,
    ]
    lazy var messageReceivers: [any MessageReceiver] = [
        TranscriptionStreamReceiver(room: room), // Keep for audio transcriptions
        localMessageSender, // Keep for loopback messages
    ]

    // MARK: Error

    lazy var errorHandler: (Error?) -> Void = { _ in }
}

/// A property wrapper that injects a dependency from the ``Dependencies`` container.
@MainActor
@propertyWrapper
struct Dependency<T> {
    let keyPath: KeyPath<Dependencies, T>

    init(_ keyPath: KeyPath<Dependencies, T>) {
        self.keyPath = keyPath
    }

    var wrappedValue: T {
        Dependencies.shared[keyPath: keyPath]
    }
}
