import Foundation

/// Main configuration for a conversation session
public struct ConversationConfig: Sendable {
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var conversationOverrides: ConversationOverrides?
    public var customLlmExtraBody: [String: Any]?
    public var dynamicVariables: [String: Any]?

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        conversationOverrides: ConversationOverrides? = nil,
        customLlmExtraBody: [String: Any]? = nil,
        dynamicVariables: [String: Any]? = nil
    ) {
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.conversationOverrides = conversationOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
    }
}

/// Agent behavior overrides
public struct AgentOverrides: Sendable {
    public var prompt: String?
    public var firstMessage: String?
    public var language: String?

    public init(
        prompt: String? = nil,
        firstMessage: String? = nil,
        language: String? = nil
    ) {
        self.prompt = prompt
        self.firstMessage = firstMessage
        self.language = language
    }
}

/// Text-to-speech configuration overrides
public struct TTSOverrides: Sendable {
    public var voiceId: String?

    public init(voiceId: String? = nil) {
        self.voiceId = voiceId
    }
}

/// Conversation behavior overrides
public struct ConversationOverrides: Sendable {
    public var textOnly: Bool

    public init(textOnly: Bool = false) {
        self.textOnly = textOnly
    }
}