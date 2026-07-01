import Combine
import Foundation

/// The durable, observable handle for talking to an ElevenLabs agent.
///
/// Create one and hold it for the lifetime of your screen (e.g. a SwiftUI
/// `@StateObject`). It exposes live conversation state as `@Published`
/// properties and controls as methods, so a view can bind to it directly:
///
/// ```swift
/// @StateObject private var client = ConversationClient()
///
/// var body: some View {
///     List(client.messages) { MessageBubble($0) }
///     Button("Start") {
///         Task { try await client.start(auth: .publicAgent(id: "agent_123")) }
///     }
/// }
/// ```
///
/// Each ``start(auth:config:)`` runs a fresh single-use session internally; the
/// client is reusable — call `start` again for another.
@MainActor
public final class ConversationClient: ObservableObject {
    // MARK: - Published state (mirrored from the active session)

    /// Connection lifecycle of the current session. `.idle` before the first
    /// ``start(auth:config:)``.
    @Published public private(set) var state: ConversationState = .idle

    /// The conversation transcript (canonical, reconciled by the SDK).
    @Published public private(set) var messages: [Message] = []

    /// Whether the agent is currently speaking.
    @Published public private(set) var isAgentSpeaking: Bool = false

    /// Heuristic agent state (`.listening`/`.speaking`/`.thinking`). Event-based
    /// (VAD + client events) when `ConversationConfig.agentStateConfiguration` is
    /// set; otherwise mirrors `isAgentSpeaking`.
    @Published public private(set) var agentState: AgentState = .listening

    /// Whether the **microphone (input)** is muted. Unrelated to agent output.
    @Published public private(set) var isMicMuted: Bool = true

    /// Whether the user is currently speaking while the microphone is muted.
    /// Only fires for mute modes that support detection (see ``MicrophoneMuteMode``).
    @Published public private(set) var isSpeakingWhileMuted: Bool = false

    /// Whether the **agent's audio output (playback)** is muted.
    @Published public private(set) var isAgentMuted: Bool = false

    /// Client tool calls awaiting execution or local completion by your app.
    @Published public private(set) var pendingToolCalls: [ClientToolCallEvent] = []

    /// Server-reported metadata for the current conversation (id, etc.).
    @Published public private(set) var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls (including any awaiting your approval).
    @Published public private(set) var mcpToolCalls: [MCPToolCallEvent] = []

    /// Status of the agent's MCP server connection(s).
    @Published public private(set) var mcpConnectionStatus: MCPConnectionStatusEvent?

    // MARK: - Dependencies & per-session wiring

    private let callbacks: ConversationCallbacks
    /// Test seam: when non-nil, sessions use this provider's mock connection
    /// managers instead of a live `Dependencies`.
    private let dependencyProvider: (any ConversationDependencyProvider)?

    /// The current single-use session. Internal plumbing — never exposed.
    private var session: Conversation?
    /// Subscriptions mirroring the active session's state. Reset on each
    /// ``start(auth:config:)`` so mirrors follow the live session.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// Create a client. `callbacks` apply to every session it starts. The
    /// per-session configuration is supplied at ``start(auth:config:)``.
    public init(
        callbacks: ConversationCallbacks = .init()
    ) {
        self.callbacks = callbacks
        self.dependencyProvider = nil
    }

    /// Test-only initializer that injects a dependency provider.
    init(
        callbacks: ConversationCallbacks = .init(),
        dependencyProvider: any ConversationDependencyProvider
    ) {
        self.callbacks = callbacks
        self.dependencyProvider = dependencyProvider
    }

    // MARK: - Lifecycle

    /// Start a new conversation. Any currently-active conversation is ended
    /// first, then a fresh single-use session is created and connected. `auth` is
    /// consumed here so tokens with a TTL stay fresh.
    ///
    /// - Important: Call `start` serially — do not invoke it again while a prior
    ///   `start` is still in flight (its `await` has not returned). Although this
    ///   type is `@MainActor`, `start` spans suspension points, so two
    ///   overlapping calls can interleave: the later call rebinds the client to a
    ///   new session and orphans the first still-connecting session (a leaked
    ///   transport with no handle left to end it). Drive `start`/`endConversation`
    ///   from a single owner (e.g. one screen's view model) and await each before
    ///   beginning the next.
    ///
    /// - Parameters:
    ///   - auth: Authentication for this session.
    ///   - config: Configuration for this session. Defaults to ``ConversationConfig/default``.
    public func start(
        auth: ConversationAuth,
        config: ConversationConfig = .default
    ) async throws {
        if let session, !session.state.isInactive {
            await session.endConversation()
        }

        let conversation = Conversation(
            dependencyProvider: dependencyProvider,
            config: config,
            callbacks: callbacks
        )
        bind(conversation)
        // `bind` synchronously seeds the mirrors from the session's `.idle`
        // defaults; connect then drives them through the startup transitions.
        try await conversation.connect(auth: auth)
    }

    /// End the current conversation, if any. The transcript and terminal state
    /// remain published until the next ``start(auth:config:)``.
    public func endConversation() async {
        await session?.endConversation()
    }

    /// Clear a terminated session (``ConversationState/startupFailed(_:)`` or
    /// ``ConversationState/ended(reason:)``) back to ``ConversationState/idle``,
    /// discarding the published transcript and metadata. Use it to dismiss an
    /// error or a finished transcript without starting a new conversation. A
    /// no-op while idle or while a session is connecting/connected — end it first.
    public func reset() {
        session?.reset()
    }

    /// Mirror the new session's `@Published` state onto this object.
    private func bind(_ session: Conversation) {
        cancellables.removeAll()
        self.session = session

        session.$state.sink { [weak self] in self?.state = $0 }.store(in: &cancellables)
        session.$messages.sink { [weak self] in self?.messages = $0 }.store(in: &cancellables)
        session.$isAgentSpeaking.sink { [weak self] in self?.isAgentSpeaking = $0 }.store(in: &cancellables)
        session.$agentState.sink { [weak self] in self?.agentState = $0 }.store(in: &cancellables)
        session.$isMicMuted.sink { [weak self] in self?.isMicMuted = $0 }.store(in: &cancellables)
        session.$isSpeakingWhileMuted.sink { [weak self] in self?.isSpeakingWhileMuted = $0 }.store(in: &cancellables)
        session.$isAgentMuted.sink { [weak self] in self?.isAgentMuted = $0 }.store(in: &cancellables)
        session.$pendingToolCalls.sink { [weak self] in self?.pendingToolCalls = $0 }.store(in: &cancellables)
        session.$conversationMetadata.sink { [weak self] in self?.conversationMetadata = $0 }.store(in: &cancellables)
        session.$mcpToolCalls.sink { [weak self] in self?.mcpToolCalls = $0 }.store(in: &cancellables)
        session.$mcpConnectionStatus.sink { [weak self] in self?.mcpConnectionStatus = $0 }.store(in: &cancellables)
    }

    private func requireSession() throws -> Conversation {
        guard let session else { throw ConversationError.notConnected }
        return session
    }

    // MARK: - Messaging

    /// Send a text message to the agent.
    public func sendMessage(_ text: String) async throws {
        try await requireSession().sendMessage(text)
    }

    /// Interrupt the agent while it is speaking.
    public func interruptAgent() async throws {
        try await requireSession().interruptAgent()
    }

    /// Send a silent contextual update to the agent (no user-visible message).
    public func updateContext(_ context: String) async throws {
        try await requireSession().updateContext(context)
    }

    // MARK: - Microphone (input) mute

    /// Toggle the local microphone mute state. A best-effort no-op when there is
    /// no live session, matching the agent-mute controls.
    public func toggleMicMute() async throws {
        try await session?.toggleMicMute()
    }

    /// Mute or unmute the local microphone. A best-effort no-op when there is no
    /// live session, matching the agent-mute controls.
    public func setMicMuted(_ muted: Bool) async throws {
        try await session?.setMicMuted(muted)
    }

    // MARK: - Agent (output) mute

    /// Toggle whether the agent's audio output (playback) is muted.
    public func toggleAgentMute() {
        session?.toggleAgentMute()
    }

    /// Mute or unmute the agent's audio output (playback).
    public func setAgentMuted(_ muted: Bool) {
        session?.setAgentMuted(muted)
    }

    // MARK: - Tools & feedback

    /// Approve or reject an MCP tool-call request from the agent.
    public func sendMCPToolApproval(toolCallId: String, isApproved: Bool) async throws {
        try await requireSession().sendMCPToolApproval(toolCallId: toolCallId, isApproved: isApproved)
    }

    /// Send the result of a client tool call back to the agent.
    public func sendToolResult(
        for toolCallId: String,
        result: Any,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) async throws {
        try await requireSession().sendToolResult(
            for: toolCallId,
            result: result,
            isError: isError,
            errorType: errorType
        )
    }

    /// Mark a tool call as completed without sending a result.
    public func markToolCallCompleted(_ toolCallId: String) {
        session?.markToolCallCompleted(toolCallId)
    }

    /// Send in-conversation feedback (like/dislike) for an agent message.
    ///
    /// - Parameters:
    ///   - score: `.like` or `.dislike`.
    ///   - eventId: The `eventId` of the agent ``Message`` being rated — every agent
    ///     message in ``messages`` carries one.
    ///
    /// Throws ``ConversationError/notConnected`` if not connected. The server is
    /// last-write-wins and accepts any past agent `eventId` (re-rating overwrites;
    /// an unknown id is a no-op), so the SDK doesn't gate availability — any
    /// "rate once" UI behaviour is your app's concern.
    public func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        try await requireSession().sendFeedback(score, eventId: eventId)
    }
}
