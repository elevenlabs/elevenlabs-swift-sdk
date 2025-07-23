import Foundation

/// Main namespace & entry point for the ElevenLabs Conversation SDK.
///
/// ```swift
/// // Create a conversation instance
/// let conversation = ElevenLabs.conversation()
/// try await conversation.startConversation(with: "agent_123")
/// ```

public enum ElevenLabs {

    // MARK: - Version

    public static let version = "2.0.0"

    // MARK: - Configuration

    /// Global, optional SDK configuration. Provide once at app start.
    /// If you never call `configure(_:)`, sensible defaults are used.
    @MainActor
    public static func configure(_ configuration: Configuration) {
        Global.shared.configuration = configuration
    }

    // MARK: - Conversation Factory

    /// Create a brand new `Conversation` instance.
    ///
    /// - Parameter options: Optional per-conversation construction options.
    /// - Returns: A fresh `Conversation`.
    @MainActor
    public static func conversation(options: ConversationBootstrapOptions = .init()) -> Conversation {
        Conversation(configuration: Global.shared.configuration,
                     bootstrapOptions: options,
                     dependencyFactory: DependencyFactory())
    }

    // MARK: - Re-exports

    public typealias ConversationOptions = ConversationConfig
    public typealias IncomingEvent       = ProtocolEvents.IncomingEvent
    public typealias OutgoingEvent       = ProtocolEvents.OutgoingEvent

    // MARK: - Internal Global State

    /// Internal container for global (process-wide) configuration.
    /// This mimics the old `Dependencies` singleton but keeps it private.
    @MainActor
    fileprivate final class Global {
        static let shared = Global()
        var configuration: Configuration = .default
        private init() {}
    }
}

// MARK: - ElevenLabs.Configuration

extension ElevenLabs {
    /// Global SDK configuration.
    public struct Configuration: Sendable {
        public var apiEndpoint: URL?
        public var logLevel: LogLevel
        public var debugMode: Bool

        public init(apiEndpoint: URL? = nil,
                    logLevel: LogLevel = .warning,
                    debugMode: Bool = false) {
            self.apiEndpoint = apiEndpoint
            self.logLevel = logLevel
            self.debugMode = debugMode
        }

        public static let `default` = Configuration()
    }

    /// Minimal, per-conversation bootstrap options.
    public struct ConversationBootstrapOptions: Sendable {
        public init() {}
    }

    /// Simple log levels.
    public enum LogLevel: Int, Sendable {
        case error
        case warning
        case info
        case debug
        case trace
    }
}
