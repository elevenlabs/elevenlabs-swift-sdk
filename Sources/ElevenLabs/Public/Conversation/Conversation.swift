import Combine
import Foundation

// swiftlint:disable file_length type_body_length

/// A single-use conversation session, created by and owned by `ConversationClient`.
///
/// Coordinates the network layer (`WebRTCConnectionManager`|`WebSocketConnectionManager`),
/// protocol parser (`EventParser`), and audio device setup for one conversation.
@MainActor
final class Conversation: ObservableObject {
    // MARK: - State

    @Published var state: ConversationState = .idle
    @Published var startupState: ConversationStartupState = .idle
    @Published var startupMetrics: ConversationStartupMetrics?
    @Published var messages: [Message] = []
    @Published var agentState: ElevenLabs.AgentState = .listening
    @Published var isMuted: Bool = true // Start as true, will be updated based on actual state

    /// Stream of client tool calls that need to be executed by the app
    @Published var pendingToolCalls: [ClientToolCallEvent] = []

    /// Conversation metadata including conversation ID, received when the conversation is initialized
    @Published var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent
    @Published var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations
    @Published var mcpConnectionStatus: MCPConnectionStatusEvent?

    /// Latest audio alignment payload emitted by the agent.
    @Published var latestAudioAlignment: AudioAlignment?

    /// Latest audio event emitted by the agent.
    @Published var latestAudioEvent: AudioEvent?

    var lastAgentEventId: Int?
    var lastFeedbackSubmittedEventId: Int?

    /// Pending mute state to apply after connection completes.
    private var pendingMuteState: Bool?

    private var audioManager: ConversationAudioManager?

    var agentStateManager: AgentStateManager?

    /// Forward a signal to the event-based state manager, or fall back to directly setting `agentState`.
    func applyStateSignal(_ signal: AgentStateSignal, fallback: ElevenLabs.AgentState) {
        if let manager = agentStateManager {
            manager.processSignal(signal)
        } else {
            agentState = fallback
        }
    }

    private func handleRemoteSpeakingUpdate(isSpeaking: Bool) {
        if let manager = agentStateManager {
            manager.processSignal(isSpeaking ? .agentStartedSpeaking : .agentStoppedSpeaking)
        } else if isSpeaking {
            speakingTimer?.cancel()
            agentState = .speaking
        } else {
            scheduleBackToListening(delay: 1.0)
        }
    }

    /// Internal logger, accessible from nonisolated contexts.
    nonisolated let logger: any Logging

    /// Context for logging (e.g. agentId)
    private var activeContext: [String: String]?

    // MARK: - Init

    init(
        dependencyProvider: any ConversationDependencyProvider,
        config: ConversationConfig = .init(),
        callbacks: ConversationCallbacks = .init()
    ) {
        self.dependencyProvider = dependencyProvider
        self.config = config
        self.callbacks = callbacks
        logger = dependencyProvider.logger
        setupAudioManager()
    }

    private func setupAudioManager() {
        guard !config.conversationOverrides.textOnly else { return }
        audioManager = ConversationAudioManager(logger: logger)
    }

    private func setupAgentStateManager() {
        guard let configuration = config.agentStateConfiguration else { return }
        let manager = AgentStateManager(configuration: configuration)
        manager.onStateChange = { [weak self] state in
            self?.agentState = state
            self?.callbacks.onAgentStateChange?(state)
        }
        agentStateManager = manager
    }

    // MARK: - API

    /// Start this single-use session. Only valid from `.idle` (including after a failed start).
    /// Once the session has `.ended`, create a new `Conversation` via `ConversationClient`.
    func startConversation(
        auth: ConversationCredentials,
        config: ConversationConfig = .init()
    ) async throws {
        guard state == .idle else {
            throw ConversationError.alreadyActive
        }

        let result: StartupResult = if config.conversationOverrides.textOnly {
            try await startTextOnlyConversation(auth: auth, config: config, provider: dependencyProvider)
        } else {
            try await startVoiceConversation(auth: auth, config: config, provider: dependencyProvider)
        }

        state = .active(.init(agentId: result.agentId))
        startupMetrics = result.metrics
        updateStartupState(.active(CallInfo(agentId: result.agentId), result.metrics))
        callbacks.onAgentReady?()
    }

    private func startVoiceConversation(
        auth: ConversationCredentials,
        config: ConversationConfig,
        provider: any ConversationDependencyProvider
    ) async throws -> StartupResult {
        let webRTCConnectionManager = provider.webRTCConnectionManager
        await prepareConversationStart(
            auth: auth, config: config,
            connectionManager: webRTCConnectionManager
        )

        webRTCConnectionManager.onRemoteSpeakingChanged = { [weak self] isSpeaking in
            Task { @MainActor in
                self?.handleRemoteSpeakingUpdate(isSpeaking: isSpeaking)
            }
        }

        await audioManager?.configure(with: config)

        let result: StartupResult
        do {
            result = try await webRTCConnectionManager.connect(
                auth: auth,
                config: config,
                onStartupStateChange: { [weak self] newState in
                    self?.updateStartupState(newState)
                }
            )
        } catch let failure as StartupFailure {
            await handleStartupFailure(failure, disconnecting: webRTCConnectionManager, suggestLocalNetworkPermission: true)
            throw failure.error
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: webRTCConnectionManager)
            throw CancellationError()
        }

        if let pendingMute = pendingMuteState {
            pendingMuteState = nil
            do {
                try await webRTCConnectionManager.setMicrophoneMuted(pendingMute)
                isMuted = pendingMute
            } catch {
                logger.warning("Failed to apply pending mute state", context: ["error": "\(error)"])
            }
        }

        isMuted = webRTCConnectionManager.isMicrophoneMuted
        return result
    }

    private func startTextOnlyConversation(
        auth: ConversationCredentials,
        config: ConversationConfig,
        provider: ConversationDependencyProvider
    ) async throws -> StartupResult {
        let connectionManager = provider.webSocketConnectionManager
        await prepareConversationStart(
            auth: auth, config: config,
            connectionManager: connectionManager
        )

        updateStartupState(.connectingRoom)

        do {
            return try await connectionManager.connect(auth: auth, config: config)
        } catch let failure as StartupFailure {
            await handleStartupFailure(failure, disconnecting: connectionManager, suggestLocalNetworkPermission: false)
            throw failure.error
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: connectionManager)
            throw CancellationError()
        }
    }

    /// End and clean up. Callable during connect (cancel) or while active.
    func endConversation(
        disconnectReason: DisconnectionReason = .user,
        endReason: EndReason = .userEnded
    ) async {
        guard state.isActive || state == .connecting else { return }
        guard let connectionManager = activeConnectionManager else {
            if state == .connecting {
                state = .idle
                tearDown()
            }
            return
        }
        state = .ended(reason: endReason)

        await connectionManager.disconnect()
        tearDown()

        callbacks.onDisconnect?(disconnectReason)
        callbacks.onCanSendFeedbackChange?(false)
    }

    /// Send a text message to the agent.
    func sendMessage(_ text: String) async throws {
        guard state.isActive else {
            throw ConversationError.notConnected
        }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        appendMessage(role: .user, content: text)
    }

    /// Toggle / set microphone
    func toggleMute() async throws {
        try await setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) async throws {
        if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
            softwareMuteProcessor.setMuted(muted)
            isMuted = muted
            return
        }
        try await setMicrophoneMuted(muted)
    }

    /// Mute the microphone. Normally calling setMuted will mute the microphone
    /// but if software mute is enabled, the setMuted call will just toggle
    /// the software mute. If you still want to explicitly mute the microphone
    /// you can use this method.
    func setMicrophoneMuted(_ muted: Bool) async throws {
        if state.isActive {
            guard let webRTCConnectionManager = activeWebRTCConnectionManager else {
                throw ConversationError.notConnected
            }
            do {
                try await webRTCConnectionManager.setMicrophoneMuted(muted)
                isMuted = muted
                pendingMuteState = nil
            } catch WebRTCConnectionManagerError.roomUnavailable {
                throw ConversationError.notConnected
            } catch {
                throw ConversationError.microphoneToggleFailed(error)
            }
        } else if state == .connecting {
            // Buffer the mute state to apply after connection completes
            pendingMuteState = muted
            isMuted = muted
        } else {
            throw ConversationError.notConnected
        }
    }

    /// Interrupt the agent while speaking.
    func interruptAgent() async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let event = OutgoingEvent.userActivity
        try await publish(event)
    }

    /// Contextual update to agent (system prompt-ish).
    func updateContext(_ context: String) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let event = OutgoingEvent.contextualUpdate(ContextualUpdateEvent(text: context))
        try await publish(event)
    }

    /// Send feedback (like/dislike) for an event/message id.
    func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        guard state.isActive else {
            throw ConversationError.notConnected
        }

        let event = OutgoingEvent.feedback(FeedbackEvent(score: score, eventId: eventId))
        try await publish(event)
        lastFeedbackSubmittedEventId = eventId
        callbacks.onCanSendFeedbackChange?(false)
    }

    /// Approve or reject an MCP tool call request from the agent.
    /// - Parameters:
    ///   - toolCallId: The tool call identifier from `MCPToolCallEvent`.
    ///   - isApproved: Pass `true` to approve, `false` to reject.
    func sendMCPToolApproval(toolCallId: String, isApproved: Bool) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let approval = MCPToolApprovalResultEvent(toolCallId: toolCallId, isApproved: isApproved)
        try await publish(.mcpToolApprovalResult(approval))
    }

    /// Send the result of a client tool call back to the agent.
    ///
    /// The `Encodable` result is JSON-encoded before sending.
    func sendToolResult(
        for toolCallId: String,
        result: some Encodable,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) async throws {
        let json = try String(decoding: JSONEncoder().encode(result), as: UTF8.self)
        // `json` is statically a String, so this dispatches to the String overload
        // below (a concrete match beats the generic) — not a recursive call.
        try await sendToolResult(for: toolCallId, result: json, isError: isError, errorType: errorType)
    }

    /// Send a client tool result that is already a string (sent verbatim).
    func sendToolResult(
        for toolCallId: String,
        result: String,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let toolResult = ClientToolResultEvent(
            toolCallId: toolCallId, result: result, isError: isError, errorType: errorType
        )
        try await publish(.clientToolResult(toolResult))
        pendingToolCalls.removeAll { $0.toolCallId == toolResult.toolCallId }
    }

    /// Mark a tool call as completed without sending a result (for tools that don't expect responses).
    func markToolCallCompleted(_ toolCallId: String) {
        pendingToolCalls.removeAll { $0.toolCallId == toolCallId }
    }

    // MARK: - Private

    private let dependencyProvider: any ConversationDependencyProvider
    private var activeConnectionManager: (any ConnectionManaging)?
    private var activeWebRTCConnectionManager: (any WebRTCConnectionManaging)? {
        activeConnectionManager as? any WebRTCConnectionManaging
    }

    private var config: ConversationConfig
    let callbacks: ConversationCallbacks

    var speakingTimer: Task<Void, Never>?

    private func updateStartupState(_ newState: ConversationStartupState) {
        startupState = newState
        callbacks.onStartupStateChange?(newState)
    }

    /// Wire handlers and move to `.connecting`. Dependency providers may reuse
    /// manager instances across sessions, so disconnect first to clear stale state.
    private func prepareConversationStart(
        auth: ConversationCredentials,
        config: ConversationConfig,
        connectionManager: any ConnectionManaging
    ) async {
        state = .connecting
        activeConnectionManager = connectionManager
        // Providers may reuse manager instances across sessions; clear stale handlers first.
        await connectionManager.disconnect()
        self.config = config

        activeContext = ["agentId": auth.agentId]
        let mode = config.conversationOverrides.textOnly ? "text-only" : "voice"
        logger.info("Starting \(mode) conversation", context: activeContext)

        callbacks.onCanSendFeedbackChange?(false)
        setupAgentStateManager()

        connectionManager.onEventReceived = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, state == .connecting || state.isActive else { return }
                await handleIncomingEvent(event)
            }
        }
        connectionManager.onDisconnected = { [weak self] in
            guard let self else { return }
            await endConversation(disconnectReason: .agent, endReason: .remoteDisconnected)
        }
    }

    private func handleStartupFailure(
        _ failure: StartupFailure,
        disconnecting connectionManager: any ConnectionManaging,
        suggestLocalNetworkPermission: Bool
    ) async {
        tearDown()
        await connectionManager.disconnect()

        startupMetrics = failure.metrics
        state = .idle
        updateStartupState(.failed(failure.reason, failure.metrics))
        callbacks.onError?(failure.error)

        if suggestLocalNetworkPermission,
           case .room = failure.reason,
           LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission()
        {
            callbacks.onError?(ConversationError.localNetworkPermissionRequired)
        }
    }

    private func handleStartupCancellation(disconnecting connectionManager: any ConnectionManaging) async {
        tearDown()
        await connectionManager.disconnect()
        startupMetrics = nil
        state = .idle
        updateStartupState(.idle)
    }

    /// Release operational resources when the session ends or fails.
    /// On a clean end, display state (messages, MCP, metadata, startup metrics) is kept
    /// so the client can still show the transcript.
    private func tearDown() {
        speakingTimer?.cancel()
        speakingTimer = nil
        pendingMuteState = nil
        agentState = .listening
        isMuted = true

        audioManager?.cleanup()
        agentStateManager = nil

        pendingToolCalls.removeAll()
        lastAgentEventId = nil
        lastFeedbackSubmittedEventId = nil
        callbacks.onCanSendFeedbackChange?(false)
        latestAudioEvent = nil
        latestAudioAlignment = nil
    }

    private func scheduleBackToListening(delay: TimeInterval = 0.5) {
        speakingTimer?.cancel()
        speakingTimer = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self.agentState = .listening
            } catch {
                // Task was cancelled, do nothing
            }
        }
    }

    func publish(_ event: OutgoingEvent) async throws {
        guard let connectionManager = activeConnectionManager else {
            throw ConversationError.notConnected
        }

        try await connectionManager.send(event: event)
    }

    // MARK: - Message Helpers

    func appendMessage(role: Message.Role, content: String, eventId: Int? = nil) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: role,
                content: content,
                timestamp: Date(),
                eventId: eventId
            )
        )
    }
}

// swiftlint:enable file_length type_body_length
