import Combine
import Foundation

/// The central entry point for the ElevenLabs Conversational AI SDK.
///
/// Create one and hold it for the lifetime of your screen (e.g. a SwiftUI
/// `@StateObject`). It exposes conversation state as `@Published` properties
/// and controls as methods. Each `startConversation` call runs a fresh,
/// single-use session internally; the client itself is reusable — call
/// `startConversation` again to start another.
@MainActor
public final class ConversationClient: ObservableObject {
    // MARK: - Public State

    @Published public private(set) var state: ConversationState = .idle
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var agentState: ElevenLabs.AgentState = .listening
    @Published public private(set) var isMicMuted: Bool = true

    /// Stream of client tool calls that need to be executed by the app
    @Published public private(set) var pendingToolCalls: [ClientToolCallEvent] = []

    /// Conversation metadata including conversation ID, received when the conversation is initialized
    @Published public private(set) var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent
    @Published public private(set) var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations
    @Published public private(set) var mcpConnectionStatus: MCPConnectionStatusEvent?

    // MARK: - Init

    private let callbacks: ConversationCallbacks
    private let dependencyProvider: (any ConversationDependencyProvider)?

    /// The current single-use session. Internal plumbing — never exposed.
    private var session: Conversation?
    /// Subscriptions mirroring the active session's state; reset on each `startConversation`.
    private var cancellables = Set<AnyCancellable>()

    public init(callbacks: ConversationCallbacks = .init()) {
        self.callbacks = callbacks
        dependencyProvider = nil
    }

    /// Test-only initializer that injects a dependency provider.
    init(callbacks: ConversationCallbacks = .init(), dependencyProvider: any ConversationDependencyProvider) {
        self.callbacks = callbacks
        self.dependencyProvider = dependencyProvider
    }

    // MARK: - Lifecycle

    /// Start a conversation with an ElevenLabs agent using a public agent ID - the most common use case.
    public func startConversation(
        agentId: String,
        config: ConversationConfig = .init()
    ) async throws -> ConversationStartResult {
        let authConfig = ConversationCredentials.publicAgent(id: agentId, environment: config.environment)
        return try await startConversation(auth: authConfig, config: config)
    }

    /// Start a conversation using a conversation token from your backend - for private agents.
    public func startConversation(
        conversationToken: String,
        config: ConversationConfig = .init()
    ) async throws -> ConversationStartResult {
        let authConfig = ConversationCredentials.conversationToken(conversationToken, environment: config.environment)
        return try await startConversation(auth: authConfig, config: config)
    }

    /// Start a conversation using a custom token provider - for advanced authentication scenarios.
    public func startConversation(
        tokenProvider: @escaping @Sendable () async throws -> String,
        config: ConversationConfig = .init()
    ) async throws -> ConversationStartResult {
        let authConfig = ConversationCredentials.customTokenProvider(tokenProvider, environment: config.environment)
        return try await startConversation(auth: authConfig, config: config)
    }

    /// Start a text-only conversation using a signed WebSocket URL from your backend.
    public func startConversation(
        signedWebSocketURL: String,
        config: ConversationConfig = .init(conversationOverrides: .init(textOnly: true))
    ) async throws -> ConversationStartResult {
        let authConfig = try ConversationCredentials.signedWebSocketURL(signedWebSocketURL)
        var updatedConfig = config
        updatedConfig.conversationOverrides.textOnly = true
        return try await startConversation(auth: authConfig, config: updatedConfig)
    }

    /// Advanced: start a conversation with full authentication control.
    ///
    /// Any previously-started session still running is ended first, then a fresh
    /// single-use session is created and connected.
    public func startConversation(
        auth: ConversationCredentials,
        config: ConversationConfig = .init()
    ) async throws -> ConversationStartResult {
        let previousConversation = session
        let conversation = Conversation(
            dependencyProvider: dependencyProvider ?? Dependencies(),
            config: config,
            callbacks: callbacks
        )
        bind(conversation)

        await previousConversation?.endConversation()
        return try await conversation.start(auth: auth)
    }

    /// End the current conversation, if any. Mirrored state (messages, etc.) is kept
    /// so the UI can still show the last session until `reset()` or a new start.
    public func endConversation() async {
        await session?.endConversation()
    }

    /// End any live session and clear all mirrored state back to idle defaults.
    /// Use this when dismissing a screen or starting over with a blank client.
    public func reset() async {
        await session?.endConversation()
        cancellables.removeAll()
        session = nil

        state = .idle
        messages = []
        agentState = .listening
        isMicMuted = true
        pendingToolCalls = []
        conversationMetadata = nil
        mcpToolCalls = []
        mcpConnectionStatus = nil
    }

    /// Mirror the new session's `@Published` state onto this object.
    private func bind(_ session: Conversation) {
        cancellables.removeAll()
        self.session = session

        session.$state.sink { [weak self] in self?.state = $0 }.store(in: &cancellables)
        session.$messages.sink { [weak self] in self?.messages = $0 }.store(in: &cancellables)
        session.$agentState.sink { [weak self] in self?.agentState = $0 }.store(in: &cancellables)
        session.$isMicMuted.sink { [weak self] in self?.isMicMuted = $0 }.store(in: &cancellables)
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

    // MARK: - Microphone

    /// Toggle / set microphone. A best-effort no-op when there is no live session.
    public func toggleMicMute() async throws {
        try await session?.toggleMicMute()
    }

    /// A best-effort no-op when there is no live session.
    public func setMicMuted(_ muted: Bool) async throws {
        try await session?.setMicMuted(muted)
    }

    // MARK: - Tools & feedback

    /// Send in-conversation feedback (like/dislike) for an agent message.
    public func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        try await requireSession().sendFeedback(score, eventId: eventId)
    }

    /// Approve or reject an MCP tool-call request from the agent.
    public func sendMCPToolApproval(toolCallId: String, isApproved: Bool) async throws {
        try await requireSession().sendMCPToolApproval(toolCallId: toolCallId, isApproved: isApproved)
    }

    /// Send the result of a client tool call back to the agent.
    ///
    /// The `Encodable` result is JSON-encoded before sending.
    public func sendToolResult(
        for toolCallId: String,
        result: some Encodable,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) async throws {
        try await requireSession().sendToolResult(
            for: toolCallId, result: result, isError: isError, errorType: errorType
        )
    }

    /// Send a client tool result that is already a string (sent verbatim).
    public func sendToolResult(
        for toolCallId: String,
        result: String,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) async throws {
        try await requireSession().sendToolResult(
            for: toolCallId, result: result, isError: isError, errorType: errorType
        )
    }

    /// Mark a tool call as completed without sending a result. A best-effort
    /// no-op when there is no live session.
    public func markToolCallCompleted(_ toolCallId: String) {
        session?.markToolCallCompleted(toolCallId)
    }
}
