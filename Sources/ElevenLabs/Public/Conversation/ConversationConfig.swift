import Foundation
import LiveKit

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
    public var conversationOverrides: ConversationOverrides?
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable
    public var userId: String?
    /// Optional environment for the agent (defaults to production when nil)
    public var environment: String?

    /// Controls timings and retry behavior for the initialization handshake
    public var startupConfiguration: ConversationStartupConfiguration

    /// Controls microphone pipeline behaviour and VAD callbacks.
    public var audioConfiguration: AudioPipelineConfiguration?

    /// Controls LiveKit peer connection behaviour, including ICE policies.
    public var networkConfiguration: LiveKitNetworkConfiguration

    /// When provided, agent state is computed from VAD scores and protocol events
    /// instead of relying on LiveKit's isSpeaking detection.
    public var agentStateConfiguration: AgentStateConfiguration?

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        conversationOverrides: ConversationOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        environment: String? = nil,
        startupConfiguration: ConversationStartupConfiguration = .default,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        networkConfiguration: LiveKitNetworkConfiguration = .default,
        agentStateConfiguration: AgentStateConfiguration? = nil
    ) {
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.conversationOverrides = conversationOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.environment = environment
        self.startupConfiguration = startupConfiguration
        self.audioConfiguration = audioConfiguration
        self.networkConfiguration = networkConfiguration
        self.agentStateConfiguration = agentStateConfiguration
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

// MARK: - Conversion Extension

extension ConversationConfig {
    /// Convert ConversationConfig to ConversationOptions for internal use
    func toConversationOptions() -> ConversationOptions {
        ConversationOptions(
            conversationOverrides: conversationOverrides ?? ConversationOverrides(),
            agentOverrides: agentOverrides,
            ttsOverrides: ttsOverrides,
            customLlmExtraBody: customLlmExtraBody,
            dynamicVariables: dynamicVariables,
            userId: userId,
            environment: environment,
            startupConfiguration: startupConfiguration,
            audioConfiguration: audioConfiguration,
            networkConfiguration: networkConfiguration,
            agentStateConfiguration: agentStateConfiguration
        )
    }
}
