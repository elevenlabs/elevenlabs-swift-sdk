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
    @Published var messages: [Message] = []
    @Published var agentState: ElevenLabs.AgentState = .listening

    /// Stream of client tool calls that need to be executed by the app
    @Published var pendingToolCalls: [ClientToolCallEvent] = []

    /// Conversation metadata including conversation ID, received when the conversation is initialized
    @Published var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent
    @Published var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations
    @Published var mcpConnectionStatus: MCPConnectionStatusEvent?

    /// Device lists (optional to expose; keep `internal` if you don't want them public)
    @Published var audioDevices: [AudioDevice] = []
    @Published var selectedAudioDeviceID: String = ""

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
    var inputTrack: LocalAudioTrack? {
        activeWebRTCConnectionManager?.inputTrack
    }

    var agentAudioTrack: RemoteAudioTrack? {
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

    // MARK: - API

    /// Start a conversation using authentication configuration.
    func start(auth: ConversationCredentials) async throws -> ConversationStartResult {
        guard state == .idle else {
            throw ConversationError.alreadyStarted
        }

        let result: ConversationStartResult = if config.conversationOverrides.textOnly {
            try await startTextOnlyConversation(auth: auth)
        } else {
            try await startVoiceConversation(auth: auth)
        }

        state = .connected(result.callInfo)
        callbacks.onAgentReady?()
        return result
    }

    private func startVoiceConversation(
        auth: ConversationCredentials
    ) async throws -> ConversationStartResult {
        let webRTCConnectionManager = dependencyProvider.webRTCConnectionManager
        prepareConversationStart(
            auth: auth,
            connectionManager: webRTCConnectionManager
        )

        webRTCConnectionManager.onRemoteSpeakingChanged = { [weak self] isSpeaking in
            Task { @MainActor in
                self?.handleRemoteSpeakingUpdate(isSpeaking: isSpeaking)
            }
        }

        await audioManager?.configure(with: config, callbacks: callbacks)
        if let pendingMuteState {
            audioManager?.softwareMuteProcessor?.setMuted(pendingMuteState)
        }

        let result: ConversationStartResult
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
                if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
                    softwareMuteProcessor.setMuted(pendingMute)
                } else {
                    try await webRTCConnectionManager.setMicrophoneMuted(pendingMute)
                }
            } catch {
                logger.warning("Failed to apply pending mute state", context: ["error": "\(error)"])
            }
        }

        return result
    }

    private func startTextOnlyConversation(
        auth: ConversationCredentials
    ) async throws -> ConversationStartResult {
        let connectionManager = dependencyProvider.webSocketConnectionManager
        prepareConversationStart(
            auth: auth,
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
    func endConversation(
        disconnectReason: DisconnectionReason = .user,
        endReason: EndReason = .userEnded
    ) async {
        if state == .idle {
            state = .ended(reason: endReason)
            tearDownActiveSession()
            return
        }

        guard state.isConnected || state.isConnecting,
              let connectionManager = activeConnectionManager
        else { return }
        state = .ended(reason: endReason)

        // Disconnect synchronously to ensure clean state
        await connectionManager.disconnect()

        tearDownActiveSession()

        // Call user's onDisconnect callback if provided
        callbacks.onDisconnect?(disconnectReason)
        callbacks.onCanSendFeedbackChange?(false)
    }

    /// Send a text message to the agent.
    func sendMessage(_ text: String) async throws {
        guard state.isConnected else {
            throw ConversationError.notConnected
        }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        appendMessage(role: .user, content: text)
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
        lastFeedbackSubmittedEventId = eventId
        callbacks.onCanSendFeedbackChange?(false)
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
        guard state.isConnected else { throw ConversationError.notConnected }
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

    let config: ConversationConfig
    let callbacks: ConversationCallbacks

    var speakingTimer: Task<Void, Never>?

    private func updateStartupStage(_ stage: ConversationStartupState) {
        guard state.isConnecting, state != .connecting(stage) else { return }
        state = .connecting(stage)
    }

    /// Common preparation shared by voice and text-only startup paths.
    private func prepareConversationStart(
        auth: ConversationCredentials,
        connectionManager: any ConnectionManaging
    ) {
        state = .connecting(.preparing)
        activeConnectionManager = connectionManager

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

        // End/supersede may have already moved us out of connecting; don't
        // overwrite `.ended` or fire shared `onError` for a discarded session.
        guard state.isConnecting else { return }
        state = .error(error)
        callbacks.onError?(error)
    }

    private func handleStartupCancellation(disconnecting connectionManager: any ConnectionManaging) async {
        guard state.isConnecting else { return }
        state = .ended(reason: .userEnded)
        await connectionManager.disconnect()
        tearDownActiveSession()
    }

    /// Tear down operational state when an active session ends.
    /// Preserves user-visible display state (messages, MCP activity, conversation
    /// metadata) so `ConversationClient` can keep the completed transcript visible.
    private func tearDownActiveSession() {
        cleanupTransientResources()

        pendingToolCalls.removeAll()

        lastAgentEventId = nil
        lastFeedbackSubmittedEventId = nil
        callbacks.onCanSendFeedbackChange?(false)
    }

    private func cleanupTransientResources() {
        speakingTimer?.cancel()
        speakingTimer = nil
        pendingMuteState = nil
        agentState = .listening

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
            insertUserTranscript(content: e.transcript, eventId: e.eventId)
            agentStateManager?.processSignal(.userTranscript)
            callbacks.onUserTranscript?(e.transcript, e.eventId)

        case let .agentResponse(e):
            upsertAgentMessage(content: e.response, eventId: e.eventId)
            lastAgentEventId = e.eventId
            agentStateManager?.processSignal(.agentResponse)
            callbacks.onAgentResponse?(e.response, e.eventId)
            if lastFeedbackSubmittedEventId.map({ e.eventId > $0 }) ?? true {
                callbacks.onCanSendFeedbackChange?(true)
            }

        case let .agentResponseCorrection(correction):
            upsertAgentMessage(content: correction.correctedAgentResponse, eventId: correction.eventId)
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
            let existing = messages.last(where: { $0.role == .agent && $0.eventId == e.eventId })?.content ?? ""
            upsertAgentMessage(content: existing + e.text, eventId: e.eventId)

        case let .audio(audioEvent):
            if let alignment = audioEvent.alignment {
                callbacks.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            speakingTimer?.cancel()
            applyStateSignal(.interruption, fallback: .listening)
            callbacks.onInterruption?(interruptionEvent.eventId)
            callbacks.onCanSendFeedbackChange?(false)

        case let .conversationMetadata(metadata):
            conversationMetadata = metadata
            callbacks.onConversationMetadata?(metadata)

        case let .ping(p):
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case let .clientToolCall(toolCall):
            callbacks.onUnhandledClientToolCall?(toolCall)
            pendingToolCalls.append(toolCall)

        case let .vadScore(vad):
            agentStateManager?.processSignal(.vadScore(vad.vadScore))
            callbacks.onVadScore?(vad.vadScore)

        case let .agentToolResponse(toolResponse):
            applyStateSignal(.agentToolResponse, fallback: .listening)

            if toolResponse.toolName == "end_call" {
                await endConversation()
            }
            callbacks.onAgentToolResponse?(toolResponse)

        case let .agentToolRequest(toolRequest):
            applyStateSignal(.agentToolRequest, fallback: .thinking)
            callbacks.onAgentToolRequest?(toolRequest)

        case .tentativeUserTranscript:
            break

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

    /// Inserts the user transcript before the agent message with the same `eventId`
    /// if one exists, since the agent's response may be received before the transcript.
    private func insertUserTranscript(content: String, eventId: Int) {
        let message = Message(
            id: UUID().uuidString,
            role: .user,
            content: content,
            timestamp: Date(),
            eventId: eventId
        )
        if let agentIdx = messages.firstIndex(where: { $0.role == .agent && $0.eventId == eventId }) {
            messages.insert(message, at: agentIdx)
        } else {
            messages.append(message)
        }
    }

    private func upsertAgentMessage(content: String, eventId: Int) {
        if let idx = messages.lastIndex(where: { $0.role == .agent && $0.eventId == eventId }) {
            let existing = messages[idx]
            messages[idx] = Message(
                id: existing.id,
                role: .agent,
                content: content,
                timestamp: existing.timestamp,
                eventId: eventId
            )
        } else {
            appendMessage(role: .agent, content: content, eventId: eventId)
        }
    }
}

// swiftlint:enable file_length type_body_length
