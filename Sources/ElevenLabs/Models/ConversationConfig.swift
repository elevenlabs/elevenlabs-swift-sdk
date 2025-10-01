import Foundation

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

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        conversationOverrides: ConversationOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil
    ) {
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.conversationOverrides = conversationOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.onAgentReady = onAgentReady
        self.onDisconnect = onDisconnect
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
        return ConversationOptions(
            conversationOverrides: conversationOverrides ?? ConversationOverrides(),
            agentOverrides: agentOverrides,
            ttsOverrides: ttsOverrides,
            customLlmExtraBody: customLlmExtraBody,
            dynamicVariables: dynamicVariables,
            userId: userId,
            onAgentReady: onAgentReady,
            onDisconnect: onDisconnect
        )
    }
}
