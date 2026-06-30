import Foundation

/// Reason for the conversation disconnection
public enum DisconnectionReason: Sendable {
    case agent
    case user
}

extension DisconnectionReason {
    /// The coarse disconnection reason for an ``EndReason``. Keeps the two
    /// representations in sync from a single source so callers can use either.
    init(_ endReason: EndReason) {
        switch endReason {
        case .userEnded: self = .user
        case .remoteDisconnected: self = .agent
        }
    }
}

/// Determines how microphone setup failures are handled during connection
public enum MicrophoneFailureHandling: Sendable {
    /// Throw an error if microphone setup fails (recommended for voice-first apps)
    case throwError
    /// Log a warning but continue without microphone (useful for fallback scenarios)
    case continueWithoutMicrophone
}

/// Logging level for the SDK's internal diagnostics.
///
/// Top-level in the `ElevenLabs` module, so it can be referred to as `LogLevel`
/// or, if that name collides in your code, as `ElevenLabs.LogLevel`. Set it via
/// `ConversationConfig.logLevel`.
public enum LogLevel: Int, Comparable, Sendable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3
    case trace = 4
    /// Logs the SDK's own diagnostics at ``debug`` verbosity and *additionally*
    /// forwards LiveKit + the underlying WebRTC logs (ICE servers, candidate
    /// gathering, TURN allocation). Extremely noisy — use only when diagnosing
    /// transport/connectivity issues such as ICE or relay failures.
    case debugWithRTC = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The SDK-log threshold this level maps to. ``debugWithRTC`` keeps the
    /// SDK's own output at ``debug`` level; the WebRTC firehose is separate.
    var sdkVerbosity: LogLevel {
        self == .debugWithRTC ? .debug : self
    }

    /// Whether this level forwards LiveKit + WebRTC logs.
    var forwardsRTCLogs: Bool {
        self == .debugWithRTC
    }
}

/// A single `dynamic_variables` value. Mirrors the value types the ConvAI API
/// accepts for dynamic variables — string, integer, number, boolean, array, or
/// null. Nested objects are intentionally unsupported: dynamic variables are
/// flat placeholders substituted into the prompt, first message, and tool
/// parameters, and the API does not document object values for them.
public enum DynamicVariableValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case array([DynamicVariableValue])
    case null

    var jsonObject: Any {
        switch self {
        case let .string(value):
            return value
        case let .integer(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case let .array(values):
            return values.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }
}

extension DynamicVariableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension DynamicVariableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension DynamicVariableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension DynamicVariableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension DynamicVariableValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: DynamicVariableValue...) {
        self = .array(elements)
    }
}

extension DynamicVariableValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

/// Main configuration for a conversation session
public struct ConversationConfig: Sendable {
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?

    /// Run the conversation in text-only mode: no microphone or audio pipeline,
    /// connecting over the text WebSocket transport instead of WebRTC. Sent to the
    /// server as `conversation_config_override.conversation.text_only` when `true`.
    public var textOnly: Bool

    public var dynamicVariables: [String: DynamicVariableValue]?
    public var userId: String?
    /// Optional environment for the agent (defaults to production when nil).
    ///
    /// Applied to the requests the SDK originates — the conversation-token
    /// exchange, the public-agent WebSocket URL, and conversation REST calls. It
    /// is deliberately **not** applied to a caller-supplied
    /// ``ConversationAuth/signedWebSocketURL``, which is used verbatim because the
    /// signed URL already encodes its own environment/region.
    public var environment: String?

    /// Network endpoints used for this conversation's connections and REST calls
    /// (token exchange, voice/text WebSockets, file upload/feedback). Override to
    /// front the SDK through a proxy, regional host, or staging deployment.
    public var endpoints: ElevenLabsEndpoints

    /// How to handle microphone setup failures during connection
    public var microphoneFailureHandling: MicrophoneFailureHandling

    /// Maximum time to wait for the agent (the remote participant) to join the
    /// LiveKit room during voice startup. Voice only. Exceeding it fails startup
    /// with `.agentTimeout`. Defaults to 3 seconds.
    public var agentJoinTimeout: TimeInterval

    /// Maximum time to wait for the server to acknowledge the
    /// `conversation_initiation_client_data` handshake with
    /// `conversation_initiation_metadata`, which completes startup. Applies to
    /// both voice and text. Exceeding it fails startup with `.initializationTimeout`.
    /// Defaults to 3 seconds.
    public var conversationInitTimeout: TimeInterval

    /// Controls microphone pipeline behaviour and VAD callbacks.
    public var audioConfiguration: AudioPipelineConfiguration?

    /// Force TURN-relay-only ICE for the voice peer connection. Skips host
    /// candidate gathering, which avoids the iOS local-network permission
    /// prompt, at the cost of always relaying media through TURN. Defaults to
    /// `false` (gather all candidate types).
    public var relayOnly: Bool

    /// Verbosity of the SDK's internal diagnostics (emitted via `os.Logger`),
    /// fixed for the lifetime of the conversation this config starts. Defaults to
    /// `.warning`.
    public var logLevel: LogLevel

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        textOnly: Bool = false,
        dynamicVariables: [String: DynamicVariableValue]? = nil,
        userId: String? = nil,
        environment: String? = nil,
        endpoints: ElevenLabsEndpoints = .production,
        microphoneFailureHandling: MicrophoneFailureHandling = .throwError,
        agentJoinTimeout: TimeInterval = 3.0,
        conversationInitTimeout: TimeInterval = 3.0,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        relayOnly: Bool = false,
        logLevel: LogLevel = .warning
    ) {
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.textOnly = textOnly
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.environment = environment
        self.endpoints = endpoints
        self.microphoneFailureHandling = microphoneFailureHandling
        self.agentJoinTimeout = agentJoinTimeout
        self.conversationInitTimeout = conversationInitTimeout
        self.audioConfiguration = audioConfiguration
        self.relayOnly = relayOnly
        self.logLevel = logLevel
    }

    public static let `default` = ConversationConfig()
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