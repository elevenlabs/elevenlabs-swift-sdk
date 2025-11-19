import Foundation

// MARK: - Incoming Events (from ElevenLabs)

/// Events that can be received from the ElevenLabs agent
public enum IncomingEvent: Sendable {
    case userTranscript(UserTranscriptEvent)
    case tentativeUserTranscript(TentativeUserTranscriptEvent)
    case agentResponse(AgentResponseEvent)
    case agentResponseCorrection(AgentResponseCorrectionEvent)
    case agentChatResponsePart(AgentChatResponsePartEvent)
    case audio(AudioEvent)
    case interruption(InterruptionEvent)
    case vadScore(VadScoreEvent)
    case tentativeAgentResponse(TentativeAgentResponseEvent)
    case conversationMetadata(ConversationMetadataEvent)
    case ping(PingEvent)
    case clientToolCall(ClientToolCallEvent)
    case agentToolRequest(AgentToolRequestEvent)
    case agentToolResponse(AgentToolResponseEvent)
    case mcpToolCall(MCPToolCallEvent)
    case mcpConnectionStatus(MCPConnectionStatusEvent)
    case asrInitiationMetadata(ASRInitiationMetadataEvent)
    case error(ErrorEvent)
}

public enum AgentChatResponsePartType: String, Sendable {
    case start
    case delta
    case stop
}

/// User's speech transcription
public struct UserTranscriptEvent: Sendable {
    public let transcript: String
    public let eventId: Int
}

/// Tentative user's speech transcription (in-progress)
public struct TentativeUserTranscriptEvent: Sendable {
    public let transcript: String
    public let eventId: Int
}

/// Agent's text response
public struct AgentResponseEvent: Sendable {
    public let response: String
    public let eventId: Int
}

/// Agent's response correction
public struct AgentResponseCorrectionEvent: Sendable {
    public let originalAgentResponse: String
    public let correctedAgentResponse: String
    public let eventId: Int
}

public struct AgentChatResponsePartEvent: Sendable {
    public let text: String
    public let type: AgentChatResponsePartType
}

/// Audio alignment data showing character-level timing information
public struct AudioAlignment: Sendable {
    public let chars: [String]
    public let charStartTimesMs: [Int]
    public let charDurationsMs: [Int]
}

/// Audio data from the agent
public struct AudioEvent: Sendable {
    public let audioBase64: String
    public let eventId: Int
    public let alignment: AudioAlignment?
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
    public let userInputAudioFormat: String
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
    public let eventId: Int

    /// Get parameters as dictionary (not Sendable, use carefully)
    public func getParameters() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: parametersData) as? [String: Any] ?? [:]
    }
}

/// Agent tool request event (request initiated by the agent)
public struct AgentToolRequestEvent: Sendable {
    public let toolName: String
    public let toolCallId: String
    public let toolType: String
    public let eventId: Int
}

/// Agent tool response event
public struct AgentToolResponseEvent: Sendable {
    public let toolName: String
    public let toolCallId: String
    public let toolType: String
    public let isError: Bool
    public let eventId: Int
}

/// MCP tool call event
public struct MCPToolCallEvent: Sendable {
    public enum State: String, Sendable {
        case loading
        case awaitingApproval = "awaiting_approval"
        case success
        case failure
    }

    public let serviceId: String
    public let toolCallId: String
    public let toolName: String
    public let toolDescription: String?
    public let parametersData: Data
    public let timestamp: String
    public let state: State

    public let approvalTimeoutSecs: Int?
    public let resultData: Data?
    public let errorMessage: String?

    public func getParameters() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: parametersData) as? [String: Any] ?? [:]
    }

    public func getResult() throws -> [[String: Any]]? {
        guard let resultData else { return nil }
        return try JSONSerialization.jsonObject(with: resultData) as? [[String: Any]]
    }
}

public struct MCPConnectionStatusEvent: Sendable {
    public struct Integration: Sendable {
        public let integrationId: String
        public let integrationType: String
        public let isConnected: Bool
        public let toolCount: Int
    }

    public let integrations: [Integration]
}

/// ASR initiation metadata event
public struct ASRInitiationMetadataEvent: Sendable {
    public let metadataData: Data

    public func getMetadata() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] ?? [:]
    }
}

/// Error event placeholder
public struct ErrorEvent: Sendable {
    // TODO: Implement
}
