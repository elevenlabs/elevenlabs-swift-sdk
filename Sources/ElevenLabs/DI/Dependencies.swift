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

    lazy var tokenService = TokenService()
    lazy var connectionManager = ConnectionManager()

    private lazy var localMessageSender = LocalMessageSender(room: room)
    private lazy var dataChannelReceiver: any MessageReceiver = {
        if #available(macOS 11.0, iOS 14.0, *) {
            return DataChannelReceiver(room: room)
        } else {
            // Fallback for older OS versions - could implement a simple receiver
            return localMessageSender
        }
    }()

    lazy var messageSenders: [any MessageSender] = [
        localMessageSender,
    ]
    lazy var messageReceivers: [any MessageReceiver] = [
        dataChannelReceiver, // Primary receiver for ElevenLabs messages
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
