import Foundation

/// Main configuration for a conversation session
public struct ConversationConfig: Sendable {
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var conversationOverrides: ConversationOverrides?
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable

    public init(
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        conversationOverrides: ConversationOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil
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

// MARK: - Conversion Extension

extension ConversationConfig {
    /// Convert ConversationConfig to ConversationOptions for internal use
    func toConversationOptions() -> ConversationOptions {
        return ConversationOptions(
            conversationOverrides: conversationOverrides ?? ConversationOverrides(),
            agentOverrides: agentOverrides,
            ttsOverrides: ttsOverrides,
            customLlmExtraBody: customLlmExtraBody,
            dynamicVariables: dynamicVariables
        )
    }
}
