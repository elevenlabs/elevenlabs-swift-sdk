import Foundation

// MARK: - Incoming Events (from ElevenLabs)

/// Events that can be received from the ElevenLabs agent
enum IncomingEvent: Sendable {
    case userTranscript(UserTranscriptEvent)
    case tentativeUserTranscript(TentativeUserTranscriptEvent)
    case agentResponse(AgentResponseEvent)
    case agentResponseCorrection(AgentResponseCorrectionEvent)
    case agentResponseMetadata(AgentResponseMetadataEvent)
    case agentChatResponsePart(AgentChatResponsePartEvent)
    case audio(AudioEvent)
    case interruption(InterruptionEvent)
    case vadScore(VadScoreEvent)
    case conversationMetadata(ConversationMetadataEvent)
    case ping(PingEvent)
    case clientToolCall(ClientToolCallEvent)
    case agentToolRequest(AgentToolRequestEvent)
    case agentToolResponse(AgentToolResponseEvent)
    case mcpToolCall(MCPToolCallEvent)
    case mcpConnectionStatus(MCPConnectionStatusEvent)
    case error(ErrorEvent)
}

enum AgentChatResponsePartType: String, Sendable {
    case start
    case delta
    case stop
}

/// User's speech transcription
struct UserTranscriptEvent: Sendable {
    let transcript: String
    let eventId: Int
}

/// Tentative user's speech transcription (in-progress)
struct TentativeUserTranscriptEvent: Sendable {
    let transcript: String
    let eventId: Int
}

/// Agent's text response
struct AgentResponseEvent: Sendable {
    let response: String
    let eventId: Int
    let responseId: String
}

/// Agent's response correction
struct AgentResponseCorrectionEvent: Sendable {
    let originalAgentResponse: String
    let correctedAgentResponse: String
    let eventId: Int
    let responseId: String
}

/// Agent response metadata
struct AgentResponseMetadataEvent: Sendable {
    let eventId: Int
    let metadataData: Data
}

struct AgentChatResponsePartEvent: Sendable {
    let text: String
    let type: AgentChatResponsePartType
    let eventId: Int
    let responseId: String
}

/// Audio alignment data showing character-level timing information
public struct AudioAlignment: Sendable {
    public let chars: [String]
    public let charStartTimesMs: [Int]
    public let charDurationsMs: [Int]
}

/// Audio data from the agent
struct AudioEvent: Sendable {
    let audioBase64: String
    let eventId: Int
    let alignment: AudioAlignment?
}

/// Interruption detected
struct InterruptionEvent: Sendable {
    let eventId: Int
}

/// Conversation initialization metadata
public struct ConversationMetadataEvent: Sendable {
    public let conversationId: String
    public let agentOutputAudioFormat: String
    public let userInputAudioFormat: String
}

/// VAD score
struct VadScoreEvent: Sendable {
    let vadScore: Double
}

/// Ping event for connection health
struct PingEvent: Sendable {
    let eventId: Int
    let pingMs: Int?
}

/// Client tool call request
public struct ClientToolCallEvent: Sendable {
    public let toolName: String
    public let toolCallId: String
    public let parametersData: Data // Store as JSON data to be Sendable
    public let eventId: Int
    public let expectsResponse: Bool

    public init(
        toolName: String,
        toolCallId: String,
        parametersData: Data,
        eventId: Int,
        expectsResponse: Bool
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.parametersData = parametersData
        self.eventId = eventId
        self.expectsResponse = expectsResponse
    }

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

/// Server error event with code, optional name, and message.
public struct ErrorEvent: Sendable, Equatable {
    public let code: Int
    public let message: String?
    public let errorName: String?

    public init(code: Int, message: String? = nil, errorName: String? = nil) {
        self.code = code
        self.message = message
        self.errorName = errorName
    }
}
