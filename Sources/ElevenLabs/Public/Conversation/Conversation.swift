import AVFoundation
import Combine
import Foundation
import LiveKit

// swiftlint:disable file_length type_body_length

/// The central entry point for the ElevenLabs Conversational AI SDK.
///
/// **Role:**
/// - Manages the lifecycle of a single conversation session.
/// - Coordinates state between the network layer (`WebRTCConnectionManager`), protocol parser (`EventParser`), and the UI
/// (`ObservableObject`).
/// - Handles audio device management and permission checks.
///
/// **Usage:**
/// Create an instance via `ElevenLabs.startConversation(...)`. Use the `@Published` properties
/// to bind your UI to conversation state.
@MainActor
public final class Conversation: ObservableObject {
    // MARK: - Public State

    @Published public internal(set) var state: ConversationState = .idle
    @Published public internal(set) var startupState: ConversationStartupState = .idle
    @Published public internal(set) var startupMetrics: ConversationStartupMetrics?
    @Published public internal(set) var messages: [Message] = []
    @Published public internal(set) var agentState: ElevenLabs.AgentState = .listening
    @Published public internal(set) var isMuted: Bool = true // Start as true, will be updated based on actual state

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

    /// Track the current streaming message for chat response parts
    var currentStreamingMessage: Message?
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
        dependencies: Task<Dependencies, Never>,
        options: ConversationOptions = .default
    ) {
        dependenciesTask = dependencies
        dependencyProvider = nil
        self.options = options
        // Temporary logger until dependencies are resolved
        logger = SDKLogger(logLevel: ElevenLabs.Global.shared.configuration.logLevel)
        setupAudioManager()
    }

    init(
        dependencyProvider: any ConversationDependencyProvider,
        options: ConversationOptions = .default
    ) {
        self.dependencyProvider = dependencyProvider
        dependenciesTask = nil
        self.options = options
        logger = dependencyProvider.logger
        setupAudioManager()
    }

    private func setupAudioManager() {
        guard !options.conversationOverrides.textOnly else { return }
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
        guard let configuration = options.agentStateConfiguration else { return }
        let manager = AgentStateManager(configuration: configuration)
        manager.onStateChange = { [weak self] state in
            self?.agentState = state
            self?.options.onAgentStateChange?(state)
        }
        agentStateManager = manager
    }

    // MARK: - Public API

    /// Start a conversation with an agent using agent ID.
    ///
    /// Each call to this method creates a fresh Room object, ensuring clean state
    /// and preventing any interference from previous conversations.
    public func startConversation(
        with agentId: String,
        options: ConversationOptions = .default
    ) async throws {
        let authConfig = ElevenLabsConfiguration.publicAgent(id: agentId, environment: options.environment)
        try await startConversation(auth: authConfig, options: options)
    }

    /// Start a conversation using authentication configuration.
    ///
    /// Each call to this method creates a fresh Room object, ensuring clean state
    /// and preventing any interference from previous conversations.
    public func startConversation(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions = .default
    ) async throws {
        guard state == .idle || state.isEnded else {
            throw ConversationError.alreadyActive
        }

        let provider = await resolveDependencyProvider()

        let result = try await startVoiceConversation(auth: auth, options: options, provider: provider)

        state = .active(.init(agentId: result.agentId))
        startupMetrics = result.metrics
        updateStartupState(.active(CallInfo(agentId: result.agentId), result.metrics))
        options.onAgentReady?()
    }

    private func startVoiceConversation(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        provider: any ConversationDependencyProvider
    ) async throws -> StartupResult {
        let webRTCConnectionManager = await provider.webRTCConnectionManager()
        await prepareConversationStart(
            auth: auth, options: options,
            connectionManager: webRTCConnectionManager, provider: provider
        )

        webRTCConnectionManager.onRemoteSpeakingChanged = { [weak self] isSpeaking in
            Task { @MainActor in
                self?.handleRemoteSpeakingUpdate(isSpeaking: isSpeaking)
            }
        }

        if audioManager == nil {
            setupAudioManager()
        }
        await audioManager?.configure(with: options)

        let result: StartupResult
        do {
            result = try await WebRTCConversationStartup(logger: logger).execute(
                auth: auth,
                options: options,
                provider: provider,
                onStateChange: { [weak self] newState in
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

    /// End and clean up.
    /// Can be called during connection phase to cancel, or during active conversation to end.
    public func endConversation() async {
        await endConversation(disconnectReason: .user, endReason: .userEnded)
    }

    private func endConversation(disconnectReason: DisconnectionReason = .user, endReason: EndReason = .userEnded) async {
        // Allow ending during both active and connecting states
        guard state.isActive || state == .connecting else { return }
        guard let connectionManager = activeConnectionManager else {
            // No connection manager yet, just reset state
            if state == .connecting {
                state = .idle
                cleanupPreviousConversation()
            }
            return
        }
        state = .ended(reason: endReason)

        // Disconnect synchronously to ensure clean state
        await connectionManager.disconnect()

        cleanupPreviousConversation()

        // Call user's onDisconnect callback if provided
        options.onDisconnect?(disconnectReason)
        options.onCanSendFeedbackChange?(false)
    }

    /// Send a text message to the agent.
    public func sendMessage(_ text: String) async throws {
        guard state.isActive else {
            throw ConversationError.notConnected
        }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        appendLocalMessage(text)
    }

    /// Toggle / set microphone
    public func toggleMute() async throws {
        try await setMuted(!isMuted)
    }

    public func setMuted(_ muted: Bool) async throws {
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
    public func setMicrophoneMuted(_ muted: Bool) async throws {
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
    public func interruptAgent() async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let event = OutgoingEvent.userActivity
        try await publish(event)
    }

    /// Contextual update to agent (system prompt-ish).
    public func updateContext(_ context: String) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let event = OutgoingEvent.contextualUpdate(ContextualUpdateEvent(text: context))
        try await publish(event)
    }

    /// Send feedback (like/dislike) for an event/message id.
    public func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        guard state.isActive else {
            throw ConversationError.notConnected
        }

        let event = OutgoingEvent.feedback(FeedbackEvent(score: score, eventId: eventId))
        try await publish(event)
        lastFeedbackSubmittedEventId = eventId
        options.onCanSendFeedbackChange?(false)
    }

    /// Approve or reject an MCP tool call request from the agent.
    /// - Parameters:
    ///   - toolCallId: The tool call identifier from `MCPToolCallEvent`.
    ///   - isApproved: Pass `true` to approve, `false` to reject.
    public func sendMCPToolApproval(toolCallId: String, isApproved: Bool) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let approval = MCPToolApprovalResultEvent(toolCallId: toolCallId, isApproved: isApproved)
        try await publish(.mcpToolApprovalResult(approval))
    }

    /// Send the result of a client tool call back to the agent.
    public func sendToolResult(for toolCallId: String, result: Any, isError: Bool = false)
        async throws
    {
        guard state.isActive else { throw ConversationError.notConnected }
        let toolResult = try ClientToolResultEvent(
            toolCallId: toolCallId, result: result, isError: isError
        )
        let event = OutgoingEvent.clientToolResult(toolResult)
        try await publish(event)

        // Remove the tool call from pending list
        pendingToolCalls.removeAll { $0.toolCallId == toolCallId }
    }

    /// Mark a tool call as completed without sending a result (for tools that don't expect responses).
    public func markToolCallCompleted(_ toolCallId: String) {
        pendingToolCalls.removeAll { $0.toolCallId == toolCallId }
    }

    // MARK: - Private

    private var dependencyProvider: (any ConversationDependencyProvider)?
    private let dependenciesTask: Task<Dependencies, Never>?
    private var activeConnectionManager: (any ConnectionManaging)?
    private var activeWebRTCConnectionManager: (any WebRTCConnectionManaging)? {
        activeConnectionManager as? any WebRTCConnectionManaging
    }

    var options: ConversationOptions

    var speakingTimer: Task<Void, Never>?

    private func resolveDependencyProvider() async -> any ConversationDependencyProvider {
        if let provider = dependencyProvider {
            return provider
        }

        if let dependenciesTask {
            let deps = await dependenciesTask.value
            dependencyProvider = deps
            // Note: errorHandler setup is handled when webRTCConnectionManager is retrieved
            return deps
        }

        guard let dependencyProvider else {
            logger.error("Conversation dependency provider not configured")
            fatalError("Conversation dependency provider not configured")
        }
        return dependencyProvider
    }

    private func updateStartupState(_ newState: ConversationStartupState) {
        startupState = newState
        options.onStartupStateChange?(newState)
    }

    private func prepareConversationStart(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        connectionManager: any ConnectionManaging,
        provider: any ConversationDependencyProvider
    ) async {
        let previousConnectionManager = activeConnectionManager
        state = .connecting

        if let previousConnectionManager, previousConnectionManager !== connectionManager {
            await previousConnectionManager.disconnect()
        }

        activeConnectionManager = connectionManager
        // Reset the target manager too; dependency providers may reuse manager instances across starts.
        await connectionManager.disconnect()
        cleanupPreviousConversation()
        self.options = options

        activeContext = ["agentId": auth.agentId]
        logger.info("Starting conversation", context: activeContext)

        options.onCanSendFeedbackChange?(false)
        setupAgentStateManager()

        connectionManager.onEventReceived = { [weak self, weak connectionManager] event in
            Task { @MainActor [weak self, weak connectionManager] in
                guard let self,
                      let connectionManager,
                      activeConnectionManager === connectionManager,
                      state == .connecting || state.isActive
                else {
                    return
                }

                await handleIncomingEvent(event)
            }
        }
        connectionManager.errorHandler = provider.errorHandler
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
        cleanupTransientResources()
        await connectionManager.disconnect()

        startupMetrics = failure.metrics
        state = .idle
        updateStartupState(.failed(failure.reason, failure.metrics))
        options.onError?(failure.error)

        if suggestLocalNetworkPermission,
           case .room = failure.reason,
           LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission()
        {
            options.onError?(ConversationError.localNetworkPermissionRequired)
        }
    }

    private func handleStartupCancellation(disconnecting connectionManager: any ConnectionManaging) async {
        cleanupTransientResources()
        await connectionManager.disconnect()
        startupMetrics = nil
        state = .idle
        updateStartupState(.idle)
    }

    /// Clean up state from any previous conversation to ensure a fresh start.
    /// This method ensures that each new conversation starts with a clean slate,
    /// preventing any state leakage between conversations when using new Room objects.
    private func cleanupPreviousConversation() {
        cleanupTransientResources()

        // Clear conversation state
        messages.removeAll()
        pendingToolCalls.removeAll()
        mcpToolCalls.removeAll()
        mcpConnectionStatus = nil
        conversationMetadata = nil
        currentStreamingMessage = nil

        startupState = .idle
        startupMetrics = nil

        lastAgentEventId = nil
        lastFeedbackSubmittedEventId = nil
        options.onCanSendFeedbackChange?(false)
        latestAudioEvent = nil
        latestAudioAlignment = nil

        logger.debug("Previous conversation state cleaned up for fresh Room", context: activeContext)
    }

    private func cleanupTransientResources() {
        speakingTimer?.cancel()
        speakingTimer = nil
        pendingMuteState = nil
        agentState = .listening
        isMuted = true

        audioManager?.cleanup()
        agentStateManager = nil
    }

    // MARK: - Testing Hooks

    @MainActor
    // swiftlint:disable:next identifier_name
    func _testing_handleIncomingEvent(_ event: IncomingEvent) async {
        await handleIncomingEvent(event)
    }

    // swiftlint:disable:next identifier_name
    func _testing_setState(_ newState: ConversationState) {
        state = newState
    }

    // swiftlint:disable:next identifier_name
    func _testing_setWebRTCConnectionManager(_ manager: any WebRTCConnectionManaging) {
        activeConnectionManager = manager
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

    func appendLocalMessage(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: text,
                timestamp: Date()
            )
        )
    }

    func appendAgentMessage(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .agent,
                content: text,
                timestamp: Date()
            )
        )
    }

    func appendUserTranscript(_ text: String) {
        // If you want partial transcript merging, do it here
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: text,
                timestamp: Date()
            )
        )
    }
}

// swiftlint:enable file_length type_body_length
