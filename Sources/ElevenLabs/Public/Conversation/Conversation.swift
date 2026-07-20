import Combine
import Foundation
import LiveKit

// swiftlint:disable file_length type_body_length

/// The central entry point for the ElevenLabs Conversational AI SDK.
///
/// **Role:**
/// - Manages the lifecycle of a single conversation session.
/// - Coordinates state between the network layer (`WebRTCConnectionManager`|`WebSocketConnectionManager`), protocol parser
/// (`EventParser`), and the UI (`ObservableObject`).
/// - Handles audio device management and permission checks.
///
/// **Usage:**
/// Create an instance via `ElevenLabs.startConversation(...)`. Use the `@Published` properties
/// to bind your UI to conversation state.
@MainActor
public final class Conversation: ObservableObject {
    // MARK: - Public State

    @Published public internal(set) var state: ConversationState = .idle
    @Published public internal(set) var messages: [Message] = []
    @Published public internal(set) var agentState: ElevenLabs.AgentState = .listening
    @Published public internal(set) var isMicMuted: Bool = true

    /// Stream of client tool calls that need to be executed by the app
    @Published public internal(set) var pendingToolCalls: [ClientToolCallEvent] = []

    /// Conversation metadata including conversation ID, received when the conversation is initialized
    @Published public internal(set) var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent
    @Published public internal(set) var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations
    @Published public internal(set) var mcpConnectionStatus: MCPConnectionStatusEvent?

    /// Latest audio alignment payload emitted by the agent.
    @Published public internal(set) var latestAudioAlignment: AudioAlignment?

    /// Latest audio event emitted by the agent.
    @Published public internal(set) var latestAudioEvent: AudioEvent?

    /// Device lists (optional to expose; keep `internal` if you don't want them public)
    @Published public internal(set) var audioDevices: [AudioDevice] = []
    @Published public internal(set) var selectedAudioDeviceID: String = ""

    var lastAgentEventId: Int?
    var lastFeedbackSubmittedEventId: Int?

    /// Pending mute state to apply after connection completes.
    /// Allows setting mute state during connection phase.
    private var pendingMuteState: Bool?

    /// Audio device management
    private var audioManager: ConversationAudioManager?

    /// Agent state manager for event-based state tracking
    var agentStateManager: AgentStateManager?

    /// Forward a signal to the event-based state manager, or fall back to directly setting `agentState`.
    func applyStateSignal(_ signal: AgentStateSignal, fallback: ElevenLabs.AgentState) {
        if let manager = agentStateManager {
            manager.processSignal(signal)
        } else {
            agentState = fallback
        }
    }

    func handleRemoteSpeakingUpdate(isSpeaking: Bool) {
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

    /// Audio tracks for advanced use cases
    public var inputTrack: LocalAudioTrack? {
        activeWebRTCConnectionManager?.inputTrack
    }

    public var agentAudioTrack: RemoteAudioTrack? {
        activeWebRTCConnectionManager?.agentAudioTrack
    }

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
        let manager = ConversationAudioManager(logger: logger)
        manager.onDevicesChanged = { [weak self] devices in
            self?.audioDevices = devices
        }
        manager.onSelectedDeviceChanged = { [weak self] deviceId in
            self?.selectedAudioDeviceID = deviceId
        }
        audioManager = manager
        // Sync initial values
        audioDevices = manager.audioDevices
        selectedAudioDeviceID = manager.selectedAudioDeviceID
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

    // MARK: - Public API

    /// Start a conversation with an agent using agent ID.
    ///
    /// Each call to this method creates a fresh Room object, ensuring clean state
    /// and preventing any interference from previous conversations.
    @discardableResult
    public func startConversation(
        with agentId: String,
        config: ConversationConfig = .init()
    ) async throws -> ConversationStartResult {
        let authConfig = ConversationCredentials.publicAgent(id: agentId, environment: config.environment)
        return try await startConversation(auth: authConfig, config: config)
    }

    /// Start a conversation using authentication configuration.
    ///
    /// Each call to this method creates a fresh Room object, ensuring clean state
    /// and preventing any interference from previous conversations.
    @discardableResult
    public func startConversation(
        auth: ConversationCredentials,
        config: ConversationConfig = .init()
    ) async throws -> ConversationStartResult {
        guard state == .idle || state.isEnded || state.isError else {
            throw ConversationError.alreadyActive
        }

        let result: StartupResult = if config.conversationOverrides.textOnly {
            try await startTextOnlyConversation(auth: auth, config: config, provider: dependencyProvider)
        } else {
            try await startVoiceConversation(auth: auth, config: config, provider: dependencyProvider)
        }

        let startResult = ConversationStartResult(
            callInfo: CallInfo(agentId: result.agentId),
            metrics: result.metrics
        )
        state = .connected(startResult.callInfo)
        callbacks.onAgentReady?()
        return startResult
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

        if audioManager == nil {
            setupAudioManager()
        }
        await audioManager?.configure(with: config, callbacks: callbacks)

        let result: StartupResult
        do {
            result = try await webRTCConnectionManager.connect(
                auth: auth,
                config: config,
                onStartupStateChange: { [weak self] stage in
                    self?.updateStartupStage(stage)
                }
            )
        } catch let error as ConversationError {
            await handleStartupFailure(error, disconnecting: webRTCConnectionManager)
            throw error
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: webRTCConnectionManager)
            throw CancellationError()
        }

        if let pendingMute = pendingMuteState {
            pendingMuteState = nil
            do {
                try await webRTCConnectionManager.setMicrophoneMuted(pendingMute)
                isMicMuted = pendingMute
            } catch {
                logger.warning("Failed to apply pending mute state", context: ["error": "\(error)"])
            }
        }

        isMicMuted = webRTCConnectionManager.isMicrophoneMuted
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

        do {
            return try await connectionManager.connect(
                auth: auth,
                config: config,
                onStartupStateChange: { [weak self] stage in
                    self?.updateStartupStage(stage)
                }
            )
        } catch let error as ConversationError {
            await handleStartupFailure(error, disconnecting: connectionManager)
            throw error
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: connectionManager)
            throw CancellationError()
        }
    }

    /// End and clean up.
    /// Can be called during connection phase to cancel, or during connected conversation to end.
    public func endConversation() async {
        await endConversation(disconnectReason: .user, endReason: .userEnded)
    }

    private func endConversation(disconnectReason: DisconnectionReason = .user, endReason: EndReason = .userEnded) async {
        // Allow ending during both connected and connecting states
        guard state.isConnected || state.isConnecting else { return }
        guard let connectionManager = activeConnectionManager else {
            // No connection manager yet, just reset state
            if state.isConnecting {
                state = .idle
                tearDownActiveSession()
            }
            return
        }
        state = .ended(reason: endReason)

        // Disconnect synchronously to ensure clean state
        await connectionManager.disconnect()

        tearDownActiveSession()

        // Call user's onDisconnect callback if provided
        callbacks.onDisconnect?(disconnectReason)
        callbacks.onCanSendFeedbackChange?(false)
    }

    /// Send a text message to the agent.
    public func sendMessage(_ text: String) async throws {
        guard state.isConnected else {
            throw ConversationError.notConnected
        }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        appendMessage(role: .user, content: text)
    }

    /// Toggle the local microphone mute state.
    public func toggleMicMute() async throws {
        try await setMicMuted(!isMicMuted)
    }

    /// Mute or unmute the local microphone.
    public func setMicMuted(_ muted: Bool) async throws {
        if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
            softwareMuteProcessor.setMuted(muted)
            isMicMuted = muted
            return
        }
        try await setHardwareMicMuted(muted)
    }

    func setHardwareMicMuted(_ muted: Bool) async throws {
        if state.isConnected {
            guard let webRTCConnectionManager = activeWebRTCConnectionManager else {
                throw ConversationError.notConnected
            }
            do {
                try await webRTCConnectionManager.setMicrophoneMuted(muted)
                isMicMuted = muted
                pendingMuteState = nil
            } catch WebRTCConnectionManagerError.roomUnavailable {
                throw ConversationError.notConnected
            } catch {
                throw ConversationError.microphoneToggleFailed(error)
            }
        } else if state.isConnecting {
            // Buffer the mute state to apply after connection completes
            pendingMuteState = muted
            isMicMuted = muted
        } else {
            throw ConversationError.notConnected
        }
    }

    /// Interrupt the agent while speaking.
    public func interruptAgent() async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let event = OutgoingEvent.userActivity
        try await publish(event)
    }

    /// Contextual update to agent (system prompt-ish).
    public func updateContext(_ context: String) async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let event = OutgoingEvent.contextualUpdate(ContextualUpdateEvent(text: context))
        try await publish(event)
    }

    /// Send feedback (like/dislike) for an event/message id.
    public func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        guard state.isConnected else {
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
    public func sendMCPToolApproval(toolCallId: String, isApproved: Bool) async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let approval = MCPToolApprovalResultEvent(toolCallId: toolCallId, isApproved: isApproved)
        try await publish(.mcpToolApprovalResult(approval))
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
        let json = try String(decoding: JSONEncoder().encode(result), as: UTF8.self)
        // `json` is statically a String, so this dispatches to the String overload
        // below (a concrete match beats the generic) — not a recursive call.
        try await sendToolResult(for: toolCallId, result: json, isError: isError, errorType: errorType)
    }

    /// Send a client tool result that is already a string (sent verbatim).
    public func sendToolResult(
        for toolCallId: String,
        result: String,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    ) async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let toolResult = ClientToolResultEvent(
            toolCallId: toolCallId, result: result, isError: isError, errorType: errorType
        )
        try await publish(.clientToolResult(toolResult))
        pendingToolCalls.removeAll { $0.toolCallId == toolResult.toolCallId }
    }

    /// Mark a tool call as completed without sending a result (for tools that don't expect responses).
    public func markToolCallCompleted(_ toolCallId: String) {
        pendingToolCalls.removeAll { $0.toolCallId == toolCallId }
    }

    // MARK: - Private

    private let dependencyProvider: any ConversationDependencyProvider
    private var activeConnectionManager: (any ConnectionManaging)?
    private var activeWebRTCConnectionManager: (any WebRTCConnectionManaging)? {
        activeConnectionManager as? any WebRTCConnectionManaging
    }

    var config: ConversationConfig
    let callbacks: ConversationCallbacks

    var speakingTimer: Task<Void, Never>?

    private func updateStartupStage(_ stage: ConversationStartupState) {
        if state != .connecting(stage) {
            state = .connecting(stage)
        }
    }

    /// Common preparation shared by voice and text-only startup paths.
    private func prepareConversationStart(
        auth: ConversationCredentials,
        config: ConversationConfig,
        connectionManager: any ConnectionManaging
    ) async {
        let previousConnectionManager = activeConnectionManager
        state = .connecting(.preparing)

        if let previousConnectionManager, previousConnectionManager !== connectionManager {
            await previousConnectionManager.disconnect()
        }

        activeConnectionManager = connectionManager
        // Reset the target manager too; dependency providers may reuse manager instances across starts.
        await connectionManager.disconnect()
        cleanupPreviousConversation()
        self.config = config

        activeContext = ["agentId": auth.agentId]
        let mode = config.conversationOverrides.textOnly ? "text-only" : "voice"
        logger.info("Starting \(mode) conversation", context: activeContext)

        callbacks.onCanSendFeedbackChange?(false)
        setupAgentStateManager()

        connectionManager.onEventReceived = { [weak self, weak connectionManager] event in
            Task { @MainActor [weak self, weak connectionManager] in
                guard let self,
                      let connectionManager,
                      activeConnectionManager === connectionManager,
                      state.isConnecting || state.isConnected
                else {
                    return
                }

                await handleIncomingEvent(event)
            }
        }
        connectionManager.onDisconnected = { [weak self] in
            guard let self else { return }
            await endConversation(disconnectReason: .agent, endReason: .remoteDisconnected)
        }
    }

    private func handleStartupFailure(
        _ error: ConversationError,
        disconnecting connectionManager: any ConnectionManaging
    ) async {
        cleanupTransientResources()
        await connectionManager.disconnect()

        state = .error(error)
        callbacks.onError?(error)
    }

    private func handleStartupCancellation(disconnecting connectionManager: any ConnectionManaging) async {
        cleanupTransientResources()
        await connectionManager.disconnect()
        state = .idle
    }

    /// Clean up state from any previous conversation to ensure a fresh start.
    /// Called when starting a new session; wipes both operational and display state.
    private func cleanupPreviousConversation() {
        tearDownActiveSession()

        messages.removeAll()
        mcpToolCalls.removeAll()
        mcpConnectionStatus = nil
        conversationMetadata = nil

        logger.debug("Previous conversation state cleaned up for fresh Room", context: activeContext)
    }

    /// Tear down operational state when an active session ends.
    /// Preserves user-visible display state (messages, MCP activity, conversation
    /// metadata, startup metrics) so the transcript remains visible until a new
    /// conversation is started.
    private func tearDownActiveSession() {
        cleanupTransientResources()

        pendingToolCalls.removeAll()

        lastAgentEventId = nil
        lastFeedbackSubmittedEventId = nil
        callbacks.onCanSendFeedbackChange?(false)
        latestAudioEvent = nil
        latestAudioAlignment = nil
    }

    private func cleanupTransientResources() {
        speakingTimer?.cancel()
        speakingTimer = nil
        pendingMuteState = nil
        agentState = .listening
        isMicMuted = true

        audioManager?.cleanup()
        agentStateManager = nil
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
