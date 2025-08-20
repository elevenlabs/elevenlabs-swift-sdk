import Foundation
import LiveKit

/// Main namespace & entry point for the ElevenLabs Conversational AI SDK.
///
/// ```swift
/// // Start a conversation directly - simple and clean
/// let conversation = try await ElevenLabs.startConversation(
///     agentId: "agent_123",
///     config: .init(conversationOverrides: .init(textOnly: false))
/// )
///
/// // Send a message
/// try await conversation.sendMessage("Hello!")
///
/// // End the conversation
/// await conversation.endConversation()
/// ```

public enum ElevenLabs {
    // MARK: - Version

    public static let version = "2.0.11"

    // MARK: - Configuration

    /// Global, optional SDK configuration. Provide once at app start.
    /// If you never call `configure(_:)`, sensible defaults are used.
    @MainActor
    public static func configure(_ configuration: Configuration) {
        Global.shared.configuration = configuration
    }

    // MARK: - SDK interface

    /// Start a conversation with an ElevenLabs agent using a public agent ID - the most common use case.
    ///
    /// This method handles all the complexity of connection setup, authentication,
    /// and protocol initialization. Simply provide a public agent ID and optional configuration.
    ///
    /// - Parameters:
    ///   - agentId: The public ElevenLabs agent ID to connect to
    ///   - config: Optional conversation configuration (voice/text mode, overrides, etc.)
    ///   - onAgentReady: Optional callback triggered when the agent is ready and conversation can begin
    ///   - onDisconnect: Optional callback triggered when the agent disconnects or conversation ends
    /// - Returns: An active `Conversation` instance ready for interaction
    /// - Throws: `ConversationError` if connection fails, agent not found, or configuration invalid
    ///
    /// ```swift
    /// // Voice conversation (default) - simplest usage
    /// let conversation = try await ElevenLabs.startConversation(agentId: "agent_123")
    ///
    /// // Text-only conversation
    /// let textConversation = try await ElevenLabs.startConversation(
    ///     agentId: "agent_123",
    ///     config: .init(conversationOverrides: .init(textOnly: true))
    /// )
    ///
    /// // Conversation with event handlers
    /// let conversation = try await ElevenLabs.startConversation(
    ///     agentId: "agent_123",
    ///     onAgentReady: {
    ///         print("Agent is ready!")
    ///     },
    ///     onDisconnect: {
    ///         print("Agent disconnected")
    ///     }
    /// )
    /// ```
    @MainActor
    public static func startConversation(
        agentId: String,
        config: ConversationConfig = .init(),
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil
    ) async throws -> Conversation {
        let authConfig = ElevenLabsConfiguration.publicAgent(id: agentId)
        var updatedConfig = config
        updatedConfig.onAgentReady = onAgentReady
        updatedConfig.onDisconnect = onDisconnect
        return try await startConversation(auth: authConfig, config: updatedConfig)
    }

    /// Start a conversation using a conversation token from your backend - for private agents.
    ///
    /// Use this method when you have private agents that require authentication.
    /// Your backend should generate conversation tokens using your ElevenLabs API key.
    ///
    /// ⚠️ **Security**: Never include your ElevenLabs API key in client apps!
    ///
    /// - Parameters:
    ///   - conversationToken: The conversation token from your backend
    ///   - config: Optional conversation configuration (voice/text mode, overrides, etc.)
    ///   - onAgentReady: Optional callback triggered when the agent is ready and conversation can begin
    ///   - onDisconnect: Optional callback triggered when the agent disconnects or conversation ends
    /// - Returns: An active `Conversation` instance ready for interaction
    /// - Throws: `ConversationError` if connection fails or token is invalid
    ///
    /// ```swift
    /// // Get token from your backend
    /// let token = try await fetchTokenFromMyBackend()
    ///
    /// // Start conversation with private agent
    /// let conversation = try await ElevenLabs.startConversation(
    ///     conversationToken: token,
    ///     config: .init(
    ///         agentOverrides: .init(firstMessage: "Hello! How can I help you today?")
    ///     )
    /// )
    /// ```
    @MainActor
    public static func startConversation(
        conversationToken: String,
        config: ConversationConfig = .init(),
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil
    ) async throws -> Conversation {
        let authConfig = ElevenLabsConfiguration.conversationToken(conversationToken)
        var updatedConfig = config
        updatedConfig.onAgentReady = onAgentReady
        updatedConfig.onDisconnect = onDisconnect
        return try await startConversation(auth: authConfig, config: updatedConfig)
    }

    /// Start a conversation using a custom token provider - for advanced authentication scenarios.
    ///
    /// Use this method when you need dynamic token generation or complex authentication flows.
    ///
    /// - Parameters:
    ///   - tokenProvider: An async closure that returns a conversation token
    ///   - config: Optional conversation configuration (voice/text mode, overrides, etc.)
    ///   - onAgentReady: Optional callback triggered when the agent is ready and conversation can begin
    ///   - onDisconnect: Optional callback triggered when the agent disconnects or conversation ends
    /// - Returns: An active `Conversation` instance ready for interaction
    /// - Throws: `ConversationError` if connection fails or token provider throws
    ///
    /// ```swift
    /// // Dynamic token provider
    /// let conversation = try await ElevenLabs.startConversation(
    ///     tokenProvider: {
    ///         // Your custom authentication logic
    ///         let userAuth = try await authenticateUser()
    ///         return try await fetchElevenLabsToken(for: userAuth)
    ///     },
    ///     config: .init(conversationOverrides: .init(textOnly: false))
    /// )
    /// ```
    @MainActor
    public static func startConversation(
        tokenProvider: @escaping @Sendable () async throws -> String,
        config: ConversationConfig = .init(),
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil
    ) async throws -> Conversation {
        let authConfig = ElevenLabsConfiguration.customTokenProvider(tokenProvider)
        var updatedConfig = config
        updatedConfig.onAgentReady = onAgentReady
        updatedConfig.onDisconnect = onDisconnect
        return try await startConversation(auth: authConfig, config: updatedConfig)
    }

    /// Advanced: Start a conversation with full authentication control.
    ///
    /// This is the most flexible method that all other convenience methods use internally.
    /// Most developers should use the simpler `startConversation(agentId:)` method instead.
    ///
    /// - Parameters:
    ///   - auth: The authentication configuration
    ///   - config: Optional conversation configuration
    /// - Returns: An active `Conversation` instance ready for interaction
    @MainActor
    public static func startConversation(
        auth: ElevenLabsConfiguration,
        config: ConversationConfig = .init()
    ) async throws -> Conversation {
        let conversation = createConversation()
        try await conversation.startConversation(auth: auth, options: config.toConversationOptions())
        return conversation
    }

    // MARK: - Internal Factory Methods

    /// Creates a new Conversation instance with proper dependency injection.
    @MainActor
    private static func createConversation() -> Conversation {
        let depsTask = Task { Dependencies.shared }
        return Conversation(dependencies: depsTask)
    }

    // MARK: - Re-exports

    // Protocol event types are already public from their respective files
    // Re-export AgentState from LiveKit for SDK users
    public typealias AgentState = LiveKit.AgentState

    // Re-export audio track types for advanced audio handling
    public typealias LocalAudioTrack = LiveKit.LocalAudioTrack
    public typealias RemoteAudioTrack = LiveKit.RemoteAudioTrack
    public typealias AudioTrack = LiveKit.AudioTrack

    // Language enum is already public and accessible as ElevenLabs.Language

    // MARK: - Internal Global State

    /// Internal container for global (process-wide) configuration.
    /// This mimics the old `Dependencies` singleton but keeps it internal.
    @MainActor
    final class Global {
        static let shared = Global()
        var configuration: Configuration = .default
        private init() {}
    }
}

// MARK: - ElevenLabs.Configuration

public extension ElevenLabs {
    /// Global SDK configuration.
    struct Configuration: Sendable {
        public var apiEndpoint: URL?
        public var websocketUrl: String?
        public var logLevel: LogLevel
        public var debugMode: Bool

        public init(apiEndpoint: URL? = nil,
                    websocketUrl: String? = nil,
                    logLevel: LogLevel = .warning,
                    debugMode: Bool = false)
        {
            self.apiEndpoint = apiEndpoint
            self.websocketUrl = websocketUrl
            self.logLevel = logLevel
            self.debugMode = debugMode
        }

        public static let `default` = Configuration()
    }

    /// Minimal, per-conversation bootstrap options.
    struct ConversationBootstrapOptions: Sendable {
        public init() {}
    }

    /// Simple log levels.
    enum LogLevel: Int, Sendable {
        case error
        case warning
        case info
        case debug
        case trace
    }
}
