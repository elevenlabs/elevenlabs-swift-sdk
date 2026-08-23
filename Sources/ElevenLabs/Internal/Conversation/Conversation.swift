import Combine
import Foundation
import LiveKit

// swiftlint:disable file_length type_body_length

/// A single-use conversation session, created by and owned by `ConversationClient`.
///
/// Manages the lifecycle of one conversation: network layer
/// (`WebRTCConnectionManager`|`WebSocketConnectionManager`), protocol parser
/// (`EventParser`), and audio device setup.
@MainActor
final class Conversation: ObservableObject {
    // MARK: - State

    @Published var state: ConversationState = .idle
    @Published var chatHistory: [any ChatHistoryItem] = []
    @Published var agentState: AgentState = .listening

    private var chatHistoryReconciler = ChatHistoryReconciler()

    /// Stream of client tool calls that need to be executed by the app
    @Published var pendingToolCalls: [ClientToolCallEvent] = []

    /// Conversation metadata including conversation ID, received when the conversation is initialized
    @Published var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent
    @Published var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations
    @Published var mcpConnectionStatus: MCPConnectionStatusEvent?

    /// Pending mute state to apply after connection completes.
    /// Allows setting mute state during connection phase.
    private var pendingMuteState: Bool?

    /// Audio device management
    private var audioManager: ConversationAudioManager?

    /// Externally registered audio observers. Kept attached across track swaps.
    let agentObserverRegistry = AudioObserverRegistry()
    let micObserverRegistry = AudioObserverRegistry()

    /// Agent state manager for event-based state tracking
    var agentStateManager: AgentStateManager?

    /// Forward a signal to the event-based state manager, or fall back to directly setting `agentState`.
    func applyStateSignal(_ signal: AgentStateSignal, fallback: AgentState) {
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

    /// Internal LiveKit tracks used to attach ``ConversationAudioObserver``s.
    var inputTrack: (any AudioTrackProtocol)? {
        activeWebRTCConnectionManager?.inputTrack
    }

    var agentAudioTrack: (any AudioTrackProtocol)? {
        activeWebRTCConnectionManager?.agentAudioTrack
    }

    // MARK: - Init

    init(
        dependencyProvider: any ConversationDependencyProvider,
        config: ConversationConfig = .init(),
        callbacks: ConversationCallbacks = .init(),
        initialMicMuted: Bool = false
    ) {
        self.dependencyProvider = dependencyProvider
        self.config = config
        self.callbacks = callbacks
        pendingMuteState = initialMicMuted
        logger = dependencyProvider.logger
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

    func startVoiceConversation(_ auth: ConversationAuth.Voice) async throws -> ConversationStartResult {
        let manager = dependencyProvider.webRTCConnectionManager
        let result = try await start(agentId: auth.agentId, isTextOnly: false, using: manager) { config in
            let audioManager = ConversationAudioManager(logger: logger)
            self.audioManager = audioManager

            manager.onRemoteSpeakingChanged = { [weak self] isSpeaking in
                Task { @MainActor in
                    self?.handleRemoteSpeakingUpdate(isSpeaking: isSpeaking)
                }
            }
            manager.onTracksChanged = { [weak self] in
                Task { @MainActor in
                    self?.refreshAudioObservers()
                }
            }
            await audioManager.configure(with: config, callbacks: callbacks)
            guard state.isConnecting else {
                audioManager.cleanup()
                throw CancellationError()
            }
            if let pendingMuteState {
                audioManager.softwareMuteProcessor?.setMuted(pendingMuteState)
            }

            return try await manager.connect(
                auth: auth,
                config: config,
                onStartupStateChange: { [weak self] in self?.updateStartupStage($0) }
            )
        }

        if let pendingMute = pendingMuteState {
            pendingMuteState = nil
            do {
                if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
                    softwareMuteProcessor.setMuted(pendingMute)
                } else {
                    try await manager.setMicrophoneMuted(pendingMute)
                }
            } catch {
                logger.warning("Failed to apply pending mute state", context: ["error": "\(error)"])
            }
        }

        refreshAudioObservers()
        return try await setConnected(result)
    }

    // MARK: - Audio observers

    /// Register an observer for the agent's decoded output audio.
    func addAgentAudioObserver(_ observer: any ConversationAudioObserver) {
        guard !isTearingDown else { return }
        agentObserverRegistry.add(observer)
    }

    /// Unregister a previously added agent audio observer.
    func removeAgentAudioObserver(_ observer: any ConversationAudioObserver) {
        agentObserverRegistry.remove(observer)
    }

    /// Register an observer for the local microphone input audio.
    func addMicAudioObserver(_ observer: any ConversationAudioObserver) {
        guard !isTearingDown else { return }
        micObserverRegistry.add(observer)
    }

    /// Unregister a previously added mic audio observer.
    func removeMicAudioObserver(_ observer: any ConversationAudioObserver) {
        micObserverRegistry.remove(observer)
    }

    /// Reconcile registered observers with the currently available tracks.
    func refreshAudioObservers() {
        guard !isTearingDown else { return }
        agentObserverRegistry.attach(to: agentAudioTrack)
        micObserverRegistry.attach(to: inputTrack)
    }

    func startTextOnlyConversation(_ auth: ConversationAuth.TextOnly) async throws -> ConversationStartResult {
        let manager = dependencyProvider.webSocketConnectionManager
        let result = try await start(agentId: auth.agentId, isTextOnly: true, using: manager) { config in
            try await manager.connect(
                auth: auth,
                config: config,
                onStartupStateChange: { [weak self] in self?.updateStartupStage($0) }
            )
        }
        return try await setConnected(result)
    }

    /// End and clean up.
    /// Can be called during connection phase to cancel, or during connected conversation to end.
    func endConversation(reason: EndReason = .userEnded) async {
        if state == .idle {
            state = .ended(reason: reason)
            tearDownActiveSession()
            return
        }

        guard state.isConnected || state.isConnecting,
              let connectionManager = activeConnectionManager
        else { return }
        state = .ended(reason: reason)

        tearDownActiveSession()
        await connectionManager.disconnect()

        callbacks.onDisconnect?(reason)
    }

    /// Send a text message to the agent.
    func sendMessage(_ text: String) async throws {
        guard state.isConnected else {
            throw ConversationError.notConnected
        }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        updateChatHistory { $0.appendUserMessage(text) }
    }

    /// Mute or unmute the local microphone.
    func setMicMuted(_ muted: Bool) async throws {
        if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
            softwareMuteProcessor.setMuted(muted)
            if state.isConnecting {
                pendingMuteState = muted
            }
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
                pendingMuteState = nil
            } catch WebRTCConnectionManagerError.roomUnavailable {
                throw ConversationError.notConnected
            } catch {
                throw ConversationError.microphoneToggleFailed(error)
            }
        } else if state == .idle || state.isConnecting {
            pendingMuteState = muted
        }
    }

    /// Interrupt the agent while speaking.
    func interruptAgent() async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let event = OutgoingEvent.userActivity
        try await publish(event)
    }

    /// Contextual update to agent (system prompt-ish).
    func updateContext(_ context: String) async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let event = OutgoingEvent.contextualUpdate(ContextualUpdateEvent(text: context))
        try await publish(event)
    }

    /// Send feedback (like/dislike) for an event/message id.
    func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        guard state.isConnected else {
            throw ConversationError.notConnected
        }

        let event = OutgoingEvent.feedback(FeedbackEvent(score: score, eventId: eventId))
        try await publish(event)
    }

    /// Approve or reject an MCP tool call request from the agent.
    /// - Parameters:
    ///   - toolCallId: The tool call identifier from `MCPToolCallEvent`.
    ///   - isApproved: Pass `true` to approve, `false` to reject.
    func sendMCPToolApproval(toolCallId: String, isApproved: Bool) async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        let approval = MCPToolApprovalResultEvent(toolCallId: toolCallId, isApproved: isApproved)
        try await publish(.mcpToolApprovalResult(approval))
    }

    /// Send the result of a client tool call back to the agent.
    func sendToolResult(_ result: ClientToolResultEvent) async throws {
        guard state.isConnected else { throw ConversationError.notConnected }
        try await publish(.clientToolResult(result))
        pendingToolCalls.removeAll { $0.toolCallId == result.toolCallId }
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

    let config: ConversationConfig
    let callbacks: ConversationCallbacks

    var speakingTimer: Task<Void, Never>?
    private var isTearingDown = false

    private func updateStartupStage(_ stage: ConversationStartupState) {
        guard state.isConnecting, state != .connecting(stage) else { return }
        state = .connecting(stage)
    }

    private func start(
        agentId: String,
        isTextOnly: Bool,
        using manager: any ConnectionManaging,
        connect: (ConversationConfig) async throws -> ConversationStartResult
    ) async throws -> ConversationStartResult {
        if state != .idle {
            if state.isEnded, activeConnectionManager == nil {
                throw CancellationError()
            }
            throw ConversationError.alreadyStarted
        }

        var startConfig = config
        startConfig.conversationOverrides.textOnly = isTextOnly

        state = .connecting(.preparing)
        activeConnectionManager = manager

        activeContext = ["agentId": agentId]
        let mode = isTextOnly ? "text-only" : "voice"
        logger.info("Starting \(mode) conversation", context: activeContext)

        setupAgentStateManager()

        let connectionManagerID = ObjectIdentifier(manager)
        manager.onEventReceived = { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleIncomingEvent(event, from: connectionManagerID)
            }
        }
        manager.onDisconnected = { [weak self] in
            guard let self else { return }
            await endConversation(reason: .remoteDisconnected)
        }

        do {
            return try await connect(startConfig)
        } catch let error as ConversationError {
            await handleStartupFailure(error, disconnecting: manager)
            throw error
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: manager)
            throw CancellationError()
        }
    }

    private func setConnected(_ result: ConversationStartResult) async throws -> ConversationStartResult {
        guard !Task.isCancelled, state.isConnecting else {
            await activeConnectionManager?.disconnect()
            throw CancellationError()
        }
        state = .connected(result.callInfo)
        callbacks.onAgentReady?()
        return result
    }

    private func handleIncomingEvent(_ event: IncomingEvent, from connectionManagerID: ObjectIdentifier) async {
        guard let activeConnectionManager,
              ObjectIdentifier(activeConnectionManager) == connectionManagerID,
              state.isConnecting || state.isConnected
        else {
            return
        }
        await handleIncomingEvent(event)
    }

    private func handleStartupFailure(
        _ error: ConversationError,
        disconnecting connectionManager: any ConnectionManaging
    ) async {
        cleanupTransientResources()
        await connectionManager.disconnect()

        // End/supersede may have already moved us out of connecting; don't
        // overwrite `.ended` or fire shared `onError` for a discarded session.
        guard state.isConnecting else { return }
        state = .error(error)
        callbacks.onError?(error)
    }

    private func handleStartupCancellation(disconnecting connectionManager: any ConnectionManaging) async {
        if state.isConnecting {
            state = .ended(reason: .userEnded)
            tearDownActiveSession()
        }
        await connectionManager.disconnect()
    }

    /// Tear down operational state when an active session ends.
    /// Preserves user-visible display state (history, MCP activity, conversation
    /// metadata) so `ConversationClient` can keep the completed transcript visible.
    private func tearDownActiveSession() {
        cleanupTransientResources()

        pendingToolCalls.removeAll()
    }

    private func cleanupTransientResources() {
        isTearingDown = true
        speakingTimer?.cancel()
        speakingTimer = nil
        pendingMuteState = nil
        agentState = .listening

        agentObserverRegistry.reset()
        micObserverRegistry.reset()

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

    // MARK: - Event Handling

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case let .userTranscript(e):
            updateChatHistory { $0.receive(e) }
            agentStateManager?.processSignal(.userTranscript)
            callbacks.onUserTranscript?(e.transcript, e.eventId)

        case let .agentResponse(e):
            updateChatHistory { $0.receive(e) }
            agentStateManager?.processSignal(.agentResponse)
            callbacks.onAgentResponse?(e.response, e.eventId)

        case let .agentResponseCorrection(correction):
            updateChatHistory { $0.receive(correction) }
            callbacks.onAgentResponseCorrection?(
                correction.originalAgentResponse,
                correction.correctedAgentResponse,
                correction.eventId
            )

        case let .agentResponseMetadata(metadata):
            callbacks.onAgentResponseMetadata?(
                metadata.metadataData,
                metadata.eventId
            )

        case let .agentChatResponsePart(e):
            updateChatHistory { $0.receive(e) }

        case let .audio(audioEvent):
            if let alignment = audioEvent.alignment {
                callbacks.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            speakingTimer?.cancel()
            applyStateSignal(.interruption, fallback: .listening)
            callbacks.onInterruption?(interruptionEvent.eventId)

        case let .conversationMetadata(metadata):
            conversationMetadata = metadata
            callbacks.onConversationMetadata?(metadata)

        case let .ping(p):
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case let .clientToolCall(toolCall):
            callbacks.onClientToolCall?(toolCall)
            pendingToolCalls.append(toolCall)

        case let .vadScore(vad):
            agentStateManager?.processSignal(.vadScore(vad.vadScore))
            callbacks.onVadScore?(vad.vadScore)

        case let .agentToolResponse(toolResponse):
            updateChatHistory { $0.receive(toolResponse) }
            applyStateSignal(.agentToolResponse, fallback: .listening)

            if toolResponse.toolName == "end_call" {
                await endConversation(reason: .agentEnded)
            }
            callbacks.onAgentToolResponse?(toolResponse)

        case let .agentToolRequest(toolRequest):
            applyStateSignal(.agentToolRequest, fallback: .thinking)
            callbacks.onAgentToolRequest?(toolRequest)

        case let .tentativeUserTranscript(transcript):
            updateChatHistory { $0.receive(transcript) }

        case let .mcpToolCall(toolCall):
            if let index = mcpToolCalls.firstIndex(where: { $0.toolCallId == toolCall.toolCallId }) {
                mcpToolCalls[index] = toolCall
            } else {
                mcpToolCalls.append(toolCall)
            }

        case let .mcpConnectionStatus(status):
            mcpConnectionStatus = status

        case let .error(errorEvent):
            logger.error("Received error event from server: code=\(errorEvent.code), message=\(errorEvent.message ?? "none")")
            callbacks.onError?(.serverError(errorEvent))
        }
    }

    private func updateChatHistory(_ update: (inout ChatHistoryReconciler) -> Void) {
        update(&chatHistoryReconciler)
        chatHistory = chatHistoryReconciler.items
    }
}

// swiftlint:enable file_length type_body_length
