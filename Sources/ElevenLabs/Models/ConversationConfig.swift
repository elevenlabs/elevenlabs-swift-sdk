import Foundation
import LiveKit

/// Main configuration for a conversation session
public struct ConversationConfig: Sendable {
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var conversationOverrides: ConversationOverrides?
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable
    public var userId: String?

    /// Called when the agent is ready and the conversation can begin
    public var onAgentReady: (@Sendable () -> Void)?

    /// Called when the agent disconnects or the conversation ends
    public var onDisconnect: (@Sendable () -> Void)?

    /// Called whenever the startup state transitions
    public var onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)?

    /// Controls timings and retry behavior for the initialization handshake
    public var startupConfiguration: ConversationStartupConfiguration

    /// Controls microphone pipeline behaviour and VAD callbacks.
    public var audioConfiguration: AudioPipelineConfiguration?

    /// Controls LiveKit peer connection behaviour, including ICE policies.
    public var networkConfiguration: LiveKitNetworkConfiguration

    /// Called when a startup-related error occurs
    public var onError: (@Sendable (ConversationError) -> Void)?

    /// Called when LiveKit detects speech activity while muted.
    public var onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)?

    /// Called for each agent response with the associated event identifier.
    public var onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called when an agent response correction is received.
    public var onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)?

    /// Called for each user transcript event.
    public var onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called when conversation metadata arrives.
    public var onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)?

    /// Called when the agent emits a tool response event.
    public var onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)?

    /// Called when the agent detects an interruption.
    public var onInterruption: (@Sendable (_ eventId: Int) -> Void)?

    /// Called whenever a VAD score is emitted.
    public var onVadScore: (@Sendable (_ score: Double) -> Void)?

    /// Called when audio alignment metadata is emitted.
    public var onAudioAlignment: (@Sendable (AudioAlignment) -> Void)?

    /// Called when feedback availability changes.
    public var onCanSendFeedbackChange: (@Sendable (Bool) -> Void)?

    /// Called when a client tool call is received without a registered handler.
    public var onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)?

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        conversationOverrides: ConversationOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil,
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        startupConfiguration: ConversationStartupConfiguration = .default,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        networkConfiguration: LiveKitNetworkConfiguration = .default,
        onError: (@Sendable (ConversationError) -> Void)? = nil,
        onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)? = nil,
        onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)? = nil,
        onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)? = nil,
        onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)? = nil,
        onInterruption: (@Sendable (_ eventId: Int) -> Void)? = nil,
        onVadScore: (@Sendable (_ score: Double) -> Void)? = nil,
        onAudioAlignment: (@Sendable (AudioAlignment) -> Void)? = nil,
        onCanSendFeedbackChange: (@Sendable (Bool) -> Void)? = nil,
        onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? = nil
    ) {
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.conversationOverrides = conversationOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.onAgentReady = onAgentReady
        self.onDisconnect = onDisconnect
        self.onStartupStateChange = onStartupStateChange
        self.startupConfiguration = startupConfiguration
        self.audioConfiguration = audioConfiguration
        self.networkConfiguration = networkConfiguration
        self.onError = onError
        self.onSpeechActivity = onSpeechActivity
        self.onAgentResponse = onAgentResponse
        self.onAgentResponseCorrection = onAgentResponseCorrection
        self.onUserTranscript = onUserTranscript
        self.onConversationMetadata = onConversationMetadata
        self.onAgentToolResponse = onAgentToolResponse
        self.onInterruption = onInterruption
        self.onVadScore = onVadScore
        self.onAudioAlignment = onAudioAlignment
        self.onCanSendFeedbackChange = onCanSendFeedbackChange
        self.onUnhandledClientToolCall = onUnhandledClientToolCall
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
            onAgentReady: onAgentReady,
            onDisconnect: onDisconnect,
            onStartupStateChange: onStartupStateChange,
            startupConfiguration: startupConfiguration,
            audioConfiguration: audioConfiguration,
            networkConfiguration: networkConfiguration,
            onError: onError,
            onSpeechActivity: onSpeechActivity,
            onAgentResponse: onAgentResponse,
            onAgentResponseCorrection: onAgentResponseCorrection,
            onUserTranscript: onUserTranscript,
            onConversationMetadata: onConversationMetadata,
            onAgentToolResponse: onAgentToolResponse,
            onInterruption: onInterruption,
            onVadScore: onVadScore,
            onAudioAlignment: onAudioAlignment,
            onCanSendFeedbackChange: onCanSendFeedbackChange,
            onUnhandledClientToolCall: onUnhandledClientToolCall
        )
    }
}
