import Foundation

/// Event hooks for a conversation. Set once when the conversation is created
public struct ConversationCallbacks: Sendable {
    /// Called when the agent is ready and the conversation can begin
    public var onAgentReady: (@Sendable () -> Void)?

    /// Called when the agent disconnects or the conversation ends
    public var onDisconnect: (@Sendable (DisconnectionReason) -> Void)?

    /// Called when a startup-related error occurs
    public var onError: (@Sendable (ConversationError) -> Void)?

    /// Called when local speech is detected while the microphone is muted.
    /// Fires only for mute modes that support muted-speech detection.
    public var onSpeechDetectedWhileMuted: (@Sendable () -> Void)?

    /// Called for each agent response with the associated event identifier.
    public var onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called when an agent response correction is received.
    public var onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)?

    /// Called when agent response metadata is received.
    public var onAgentResponseMetadata: (@Sendable (_ metadataData: Data, _ eventId: Int) -> Void)?

    /// Called for each user transcript event.
    public var onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called when conversation metadata arrives.
    public var onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)?

    /// Called when the agent emits a tool response event.
    public var onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)?

    /// Called when the agent requests a tool execution.
    public var onAgentToolRequest: (@Sendable (AgentToolRequestEvent) -> Void)?

    /// Called when the agent detects an interruption.
    public var onInterruption: (@Sendable (_ eventId: Int) -> Void)?

    /// Called whenever a VAD score is emitted.
    public var onVadScore: (@Sendable (_ score: Double) -> Void)?

    /// Called when audio alignment metadata is emitted.
    public var onAudioAlignment: (@Sendable (AudioAlignment) -> Void)?

    /// Called when feedback availability changes.
    public var onCanSendFeedbackChange: (@Sendable (Bool) -> Void)?

    /// Called when a client tool call is received without a registered handler.
    public var onClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)?

    /// Called whenever the agent state changes (event-based mode only).
    public var onAgentStateChange: (@Sendable (ElevenLabs.AgentState) -> Void)?

    public init(
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable (DisconnectionReason) -> Void)? = nil,
        onError: (@Sendable (ConversationError) -> Void)? = nil,
        onSpeechDetectedWhileMuted: (@Sendable () -> Void)? = nil,
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
        onClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? = nil,
        onAgentStateChange: (@Sendable (ElevenLabs.AgentState) -> Void)? = nil
    ) {
        self.onAgentReady = onAgentReady
        self.onDisconnect = onDisconnect
        self.onError = onError
        self.onSpeechDetectedWhileMuted = onSpeechDetectedWhileMuted
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
        self.onClientToolCall = onClientToolCall
        self.onAgentStateChange = onAgentStateChange
    }
}
