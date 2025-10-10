import LiveKit

/// A minimalistic dependency injection container.
/// It allows sharing common dependencies e.g. `Room` between view models and services.
/// - Note: For production apps, consider using a more flexible approach offered by e.g.:
///   - [Factory](https://github.com/hmlongco/Factory)
///   - [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
///   - [Needle](https://github.com/uber/needle)
@MainActor
final class Dependencies {
    static let shared = Dependencies()

    private init() {}

    // MARK: LiveKit

    lazy var room = Room(roomOptions: RoomOptions(defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useBroadcastExtension: true)))

    // MARK: Services

    lazy var tokenService: TokenService = {
        let globalConfig = ElevenLabs.Global.shared.configuration
        let tokenServiceConfig = TokenService.Configuration(
            apiEndpoint: globalConfig.apiEndpoint?.absoluteString,
            websocketURL: globalConfig.websocketUrl,
        )
        return TokenService(configuration: tokenServiceConfig)
    }()

    lazy var connectionManager = ConnectionManager()

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
