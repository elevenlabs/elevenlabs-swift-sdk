import Foundation

// MARK: - Incoming Events (from ElevenLabs)

/// Events that can be received from the ElevenLabs agent
public enum IncomingEvent: Sendable {
    case userTranscript(UserTranscriptEvent)
    case agentResponse(AgentResponseEvent)
    case agentResponseCorrection(AgentResponseCorrectionEvent)
    case audio(AudioEvent)
    case interruption(InterruptionEvent)
    case vadScore(VadScoreEvent)
    case tentativeAgentResponse(TentativeAgentResponseEvent)
    case conversationMetadata(ConversationMetadataEvent)
    case ping(PingEvent)
    case clientToolCall(ClientToolCallEvent)
    case agentToolResponse(AgentToolResponseEvent)
}

/// User's speech transcription
public struct UserTranscriptEvent: Sendable {
    public let transcript: String
}

/// Agent's text response
public struct AgentResponseEvent: Sendable {
    public let response: String
}

/// Agent's response correction
public struct AgentResponseCorrectionEvent: Sendable {
    public let originalAgentResponse: String
    public let correctedAgentResponse: String
}

/// Audio data from the agent
public struct AudioEvent: Sendable {
    public let audioBase64: String?
    public let eventId: Int
}

/// Interruption detected
public struct InterruptionEvent: Sendable {
    public let eventId: Int
}

/// Tentative agent response (before finalization)
public struct TentativeAgentResponseEvent: Sendable {
    public let tentativeResponse: String
}

/// Conversation initialization metadata
public struct ConversationMetadataEvent: Sendable {
    public let conversationId: String
    public let agentOutputAudioFormat: String
    public let userInputAudioFormat: String?
}

/// VAD score
public struct VadScoreEvent: Sendable {
    public let vadScore: Double
}

/// Ping event for connection health
public struct PingEvent: Sendable {
    public let eventId: Int
    public let pingMs: Int?
}

/// Client tool call request
public struct ClientToolCallEvent: Sendable {
    public let toolName: String
    public let toolCallId: String
    public let parametersData: Data // Store as JSON data to be Sendable
    public let expectsResponse: Bool

    /// Get parameters as dictionary (not Sendable, use carefully)
    public func getParameters() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: parametersData) as? [String: Any] ?? [:]
    }
}

/// Agent tool response event
public struct AgentToolResponseEvent: Sendable {
    public let toolName: String
    public let toolCallId: String
    public let toolType: String
    public let isError: Bool
}
