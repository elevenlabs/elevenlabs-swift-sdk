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
    /// Optional environment for the agent (defaults to production when nil)
    public var environment: String?

    /// How to handle microphone setup failures during connection
    public var microphoneFailureHandling: MicrophoneFailureHandling

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
        conversationOverrides: ConversationOverrides = .init(),
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        environment: String? = nil,
        microphoneFailureHandling: MicrophoneFailureHandling = .throwError,
        startupConfiguration: ConversationStartupConfiguration = .default,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        networkConfiguration: LiveKitNetworkConfiguration = .default,
        agentStateConfiguration: AgentStateConfiguration? = nil
    ) {
        self.conversationOverrides = conversationOverrides
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.environment = environment
        self.microphoneFailureHandling = microphoneFailureHandling
        self.startupConfiguration = startupConfiguration
        self.audioConfiguration = audioConfiguration
        self.networkConfiguration = networkConfiguration
        self.agentStateConfiguration = agentStateConfiguration
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
            environment: environment,
            startupConfiguration: startupConfiguration,
            audioConfiguration: audioConfiguration,
            networkConfiguration: networkConfiguration,
            agentStateConfiguration: agentStateConfiguration
        )
    }
}
