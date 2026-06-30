import Foundation

public struct ConversationCallbacks: Sendable {
    /// Called when the agent is ready and the conversation can begin
    public var onAgentReady: (@Sendable () -> Void)?

    /// Called when the agent disconnects or the conversation ends
    public var onDisconnect: (@Sendable (DisconnectionReason) -> Void)?

    /// Called on a startup failure or a mid-session server error.
    public var onError: (@Sendable (ConversationError) -> Void)?

    /// Called for each agent response with the associated event identifier.
    public var onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called for each streamed agent response part (`agent_chat_response_part`).
    /// `type` frames the stream: `.start` and `.stop` are boundary markers whose
    /// `text` is empty, while `.delta` carries an incremental text chunk. The
    /// accumulated message is also available via ``ConversationClient/messages``
    /// (marked ``Message/isPartial`` until the finalized ``onAgentResponse`` arrives).
    public var onAgentResponsePart: (@Sendable (_ text: String, _ type: AgentChatResponsePartType, _ eventId: Int) -> Void)?

    /// Called when an agent response correction is received.
    public var onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)?

    /// Called when agent response metadata is received.
    public var onAgentResponseMetadata: (@Sendable (_ metadataData: Data, _ eventId: Int) -> Void)?

    /// Called for each user transcript event.
    public var onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called for each tentative (in-progress) user transcript. Use this to show
    /// live captions while the user is still speaking; a final
    /// ``onUserTranscript`` with the same `eventId` follows once finalized.
    public var onTentativeUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

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

    /// Called when the server reports a round-trip latency sample, in milliseconds.
    public var onPing: (@Sendable (_ pingMs: Int) -> Void)?

    /// Called when the agent requests a client tool call.
    public var onClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)?

    @available(*, deprecated, renamed: "onClientToolCall")
    public var onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? {
        get { onClientToolCall }
        set { onClientToolCall = newValue }
    }

    /// Called for every raw incoming frame, before it is dispatched to the typed
    /// callbacks above. `source` is `"ai"` or `"user"` (derived from the event
    /// type, matching the other ElevenLabs SDKs); `message` is the raw JSON
    /// string received from the transport. Intended for logging and telemetry —
    /// prefer the typed callbacks for app logic. Fires for every frame, including
    /// the `ping` heartbeat and event types the SDK does not otherwise surface,
    /// so it can be noisy. The raw string is only materialized when this is set,
    /// so leaving it `nil` adds no per-message cost.
    public var onMessage: (@Sendable (_ source: String, _ message: String) -> Void)?

    public init(
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable (DisconnectionReason) -> Void)? = nil,
        onError: (@Sendable (ConversationError) -> Void)? = nil,
        onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onAgentResponsePart: (@Sendable (_ text: String, _ type: AgentChatResponsePartType, _ eventId: Int) -> Void)? = nil,
        onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)? = nil,
        onAgentResponseMetadata: (@Sendable (_ metadataData: Data, _ eventId: Int) -> Void)? = nil,
        onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onTentativeUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)? = nil,
        onAgentToolRequest: (@Sendable (AgentToolRequestEvent) -> Void)? = nil,
        onInterruption: (@Sendable (_ eventId: Int) -> Void)? = nil,
        onVadScore: (@Sendable (_ score: Double) -> Void)? = nil,
        onAudioAlignment: (@Sendable (AudioAlignment) -> Void)? = nil,
        onPing: (@Sendable (_ pingMs: Int) -> Void)? = nil,
        onClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? = nil,
        onMessage: (@Sendable (_ source: String, _ message: String) -> Void)? = nil
    ) {
        self.onAgentReady = onAgentReady
        self.onDisconnect = onDisconnect
        self.onError = onError
        self.onAgentResponse = onAgentResponse
        self.onAgentResponsePart = onAgentResponsePart
        self.onAgentResponseCorrection = onAgentResponseCorrection
        self.onAgentResponseMetadata = onAgentResponseMetadata
        self.onUserTranscript = onUserTranscript
        self.onTentativeUserTranscript = onTentativeUserTranscript
        self.onAgentToolResponse = onAgentToolResponse
        self.onAgentToolRequest = onAgentToolRequest
        self.onInterruption = onInterruption
        self.onVadScore = onVadScore
        self.onAudioAlignment = onAudioAlignment
        self.onPing = onPing
        self.onClientToolCall = onClientToolCall
        self.onMessage = onMessage
    }
}
