import Foundation

/// Reason for the conversation disconnection
public enum DisconnectionReason: Sendable {
    case agent
    case user
    case error
}

/// Main configuration for a conversation session
public struct ConversationConfig: Sendable {
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var conversationOverrides: ConversationOverrides
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable
    public var userId: String?
    /// Optional environment for the agent (defaults to production when nil)
    public var environment: String?

    /// How to handle microphone setup failures during connection.
    /// When `false` (default), a microphone failure throws. When `true`, startup continues without a microphone.
    public var continueWithoutMicrophoneOnFailure: Bool

    /// Controls timings and retry behavior for the initialization handshake
    public var startupConfiguration: ConversationStartupConfiguration

    /// Controls microphone pipeline behaviour and VAD callbacks.
    public var audioConfiguration: AudioPipelineConfiguration?

    /// Controls WebRTC connection behaviour, including ICE policies.
    public var networkConfiguration: WebRTCConfiguration

    /// When provided, agent state is computed from VAD scores and protocol events
    /// instead of relying on LiveKit's isSpeaking detection.
    public var agentStateConfiguration: AgentStateConfiguration?

    /// Network endpoints to connect to. Override for proxies, regional hosts, or staging.
    public var endpoints: Endpoints

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        conversationOverrides: ConversationOverrides = .init(),
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        environment: String? = nil,
        continueWithoutMicrophoneOnFailure: Bool = false,
        startupConfiguration: ConversationStartupConfiguration = .default,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        networkConfiguration: WebRTCConfiguration = .default,
        agentStateConfiguration: AgentStateConfiguration? = nil,
        endpoints: Endpoints = .production
    ) {
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.conversationOverrides = conversationOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.environment = environment
        self.continueWithoutMicrophoneOnFailure = continueWithoutMicrophoneOnFailure
        self.startupConfiguration = startupConfiguration
        self.audioConfiguration = audioConfiguration
        self.networkConfiguration = networkConfiguration
        self.agentStateConfiguration = agentStateConfiguration
        self.endpoints = endpoints
    }
}

/// Agent behavior overrides
public struct AgentOverrides: Sendable {
    public var prompt: String?
    public var firstMessage: String?
    public var language: Language?

    public init(
        prompt: String? = nil,
        firstMessage: String? = nil,
        language: Language? = nil
    ) {
        self.prompt = prompt
        self.firstMessage = firstMessage
        self.language = language
    }
}

/// Text-to-speech configuration overrides
public struct TTSOverrides: Sendable {
    public var voiceId: String?
    public var stability: Double?
    public var speed: Double?
    public var similarityBoost: Double?

    public init(
        voiceId: String? = nil,
        stability: Double? = nil,
        speed: Double? = nil,
        similarityBoost: Double? = nil
    ) {
        self.voiceId = voiceId
        self.stability = stability
        self.speed = speed
        self.similarityBoost = similarityBoost
    }
}

/// Conversation behavior overrides
public struct ConversationOverrides: Sendable {
    public var textOnly: Bool
    public var clientEvents: [String]?

    public init(
        textOnly: Bool = false,
        clientEvents: [String]? = nil
    ) {
        self.textOnly = textOnly
        self.clientEvents = clientEvents
    }
}

/// The network endpoints the SDK talks to. Defaults to ``production``.
///
/// Override for proxies, regional hosts, or staging. Credentials follow these
/// endpoints — conversation tokens are sent to whichever `apiBase` is configured.
public struct Endpoints: Sendable, Equatable {
    /// Base URL for the HTTP API. Request paths are appended to it.
    public var apiBase: URL
    /// WebSocket endpoint for voice conversations.
    public var voiceWebSocket: URL
    /// WebSocket endpoint for text-only conversations.
    public var textWebSocket: URL

    public init(
        apiBase: URL = Endpoints.production.apiBase,
        voiceWebSocket: URL = Endpoints.production.voiceWebSocket,
        textWebSocket: URL = Endpoints.production.textWebSocket
    ) {
        self.apiBase = apiBase
        self.voiceWebSocket = voiceWebSocket
        self.textWebSocket = textWebSocket
    }

    public static let production = Endpoints(
        apiBase: URL(string: "https://api.elevenlabs.io")!,
        voiceWebSocket: URL(string: "wss://livekit.rtc.elevenlabs.io")!,
        textWebSocket: URL(string: "wss://api.elevenlabs.io/v1/convai/conversation")!
    )

    var conversationToken: URL {
        apiBase.appendingPathComponent("v1/convai/conversation/token")
    }
}
