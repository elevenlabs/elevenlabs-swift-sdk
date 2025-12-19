import Foundation
import LiveKit

public struct ConversationOptions: Sendable {
    
    /// Determines how microphone setup failures are handled during connection
    public enum MicrophoneFailureHandling: Sendable {
        /// Throw an error if microphone setup fails (recommended for voice-first apps)
        case throwError
        /// Log a warning but continue without microphone (useful for fallback scenarios)
        case continueWithoutMicrophone
    }
    
    public var conversationOverrides: ConversationOverrides
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable
    public var userId: String?
    
    /// How to handle microphone setup failures during connection
    public var microphoneFailureHandling: MicrophoneFailureHandling

    /// Called when the agent is ready and the conversation can begin
    public var onAgentReady: (@Sendable () -> Void)?

    /// Called when the agent disconnects or the conversation ends
    public var onDisconnect: (@Sendable (DisconnectionReason) -> Void)?

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

    /// Called for each agent response (finalized transcript) with its event identifier.
    public var onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called when an agent response is corrected.
    public var onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)?

    /// Called when agent response metadata is received.
    public var onAgentResponseMetadata: (@Sendable (_ metadataData: Data, _ eventId: Int) -> Void)?

    /// Called for each user transcript event emitted by the server.
    public var onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called whenever conversation metadata is received.
    public var onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)?

    /// Called when the agent issues a tool response.
    public var onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)?

    /// Called when the agent requests a tool execution.
    public var onAgentToolRequest: (@Sendable (AgentToolRequestEvent) -> Void)?

    /// Called when the agent detects an interruption.
    public var onInterruption: (@Sendable (_ eventId: Int) -> Void)?

    /// Called whenever the server emits a VAD score.
    public var onVadScore: (@Sendable (_ score: Double) -> Void)?

    /// Called when the agent emits audio alignment metadata for spoken words.
    public var onAudioAlignment: (@Sendable (AudioAlignment) -> Void)?

    /// Called when the client should enable/disable feedback UI.
    public var onCanSendFeedbackChange: (@Sendable (Bool) -> Void)?

    /// Called when an unhandled client tool call is received.
    public var onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)?

    public init(
        conversationOverrides: ConversationOverrides = .init(),
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        microphoneFailureHandling: MicrophoneFailureHandling = .throwError,
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable (DisconnectionReason) -> Void)? = nil,
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        startupConfiguration: ConversationStartupConfiguration = .default,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        networkConfiguration: LiveKitNetworkConfiguration = .default,
        onError: (@Sendable (ConversationError) -> Void)? = nil,
        onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)? = nil,
        onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)? = nil,
        onAgentResponseMetadata: (@Sendable (_ metadataData: Data, _ eventId: Int) -> Void)? = nil,
        onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)? = nil,
        onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)? = nil,
        onAgentToolRequest: (@Sendable (AgentToolRequestEvent) -> Void)? = nil,
        onInterruption: (@Sendable (_ eventId: Int) -> Void)? = nil,
        onVadScore: (@Sendable (_ score: Double) -> Void)? = nil,
        onAudioAlignment: (@Sendable (AudioAlignment) -> Void)? = nil,
        onCanSendFeedbackChange: (@Sendable (Bool) -> Void)? = nil,
        onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? = nil
    ) {
        self.conversationOverrides = conversationOverrides
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.microphoneFailureHandling = microphoneFailureHandling
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
        self.onAgentResponseMetadata = onAgentResponseMetadata
        self.onUserTranscript = onUserTranscript
        self.onConversationMetadata = onConversationMetadata
        self.onAgentToolResponse = onAgentToolResponse
        self.onAgentToolRequest = onAgentToolRequest
        self.onInterruption = onInterruption
        self.onVadScore = onVadScore
        self.onAudioAlignment = onAudioAlignment
        self.onCanSendFeedbackChange = onCanSendFeedbackChange
        self.onUnhandledClientToolCall = onUnhandledClientToolCall
    }

    public static let `default` = ConversationOptions()
}

extension ConversationOptions {
    func toConversationConfig() -> ConversationConfig {
        ConversationConfig(
            agentOverrides: agentOverrides,
            ttsOverrides: ttsOverrides,
            conversationOverrides: conversationOverrides,
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
            onSpeechActivity: onSpeechActivity
        )
    }
}
