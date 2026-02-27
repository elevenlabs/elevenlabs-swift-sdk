import AVFoundation
import Combine
import Foundation
import LiveKit

// swiftlint:disable file_length type_body_length

/// The central entry point for the ElevenLabs Conversational AI SDK.
///
/// **Role:**
/// - Manages the lifecycle of a single conversation session.
/// - Coordinates state between the network layer (`ConnectionManager`), protocol parser (`EventParser`), and the UI (`ObservableObject`).
/// - Handles audio device management and permission checks.
///
/// **Usage:**
/// Create an instance via `ElevenLabs.startConversation(...)`. Use the `@Published` properties
/// to bind your UI to conversation state.
@MainActor
public final class Conversation: ObservableObject, RoomDelegate {
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

    /// Internal logger, accessible from nonisolated contexts.
    nonisolated let logger: any Logging

    /// Context for logging (e.g. agentId)
    private var activeContext: [String: String]?

    /// Audio tracks for advanced use cases
    public var inputTrack: LocalAudioTrack? {
        guard let connectionManager = resolvedConnectionManager(),
              let room = connectionManager.room else { return nil }
        return room.localParticipant.firstAudioPublication?.track as? LocalAudioTrack
    }

    public var agentAudioTrack: RemoteAudioTrack? {
        guard let connectionManager = resolvedConnectionManager(),
              let room = connectionManager.room else { return nil }
        // Find the first remote participant (agent) with audio track
        return room.remoteParticipants.values.first?.firstAudioPublication?.track
            as? RemoteAudioTrack
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

    // MARK: - Public API

    /// Start a conversation with an agent using agent ID.
    ///
    /// Each call to this method creates a fresh Room object, ensuring clean state
    /// and preventing any interference from previous conversations.
    public func startConversation(
        with agentId: String,
        options: ConversationOptions = .default
    ) async throws {
        let authConfig = ElevenLabsConfiguration.publicAgent(id: agentId)
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

        // Resolve dependencies early
        let provider = await resolveDependencyProvider()
        let connectionManager = await provider.connectionManager()
        cachedConnectionManager = connectionManager

        state = .connecting

        // Disconnect previous session before starting new one.
        // This ensures clean state and prevents race conditions with ConnectionManager.
        await connectionManager.disconnect()
        cleanupPreviousConversation()
        self.options = options

        let currentAgentId = extractAgentId(from: auth)
        activeContext = ["agentId": currentAgentId]
        logger.info("Starting conversation", context: activeContext)

        if audioManager == nil {
            setupAudioManager()
        }
        await audioManager?.configure(with: options)
        options.onCanSendFeedbackChange?(false)

        connectionManager.errorHandler = provider.errorHandler

        // Set up agent ready callback
        connectionManager.onAgentReady = { [weak self] in
            self?.options.onAgentReady?()
        }

        // Set up agent disconnect callback
        connectionManager.onAgentDisconnected = { [weak self] in
            guard let self else { return }
            if state.isActive {
                state = .ended(reason: .remoteDisconnected)
                cleanupPreviousConversation()
                self.options.onDisconnect?(.agent)
            }
        }

        // Execute startup sequence using orchestrator
        let orchestrator = ConversationStartupOrchestrator(logger: logger)
        let result: StartupResult

        do {
            result = try await orchestrator.execute(
                auth: auth,
                options: options,
                provider: provider,
                onStateChange: { [weak self] newState in
                    self?.updateStartupState(newState)
                },
                onRoomConnected: { [weak self] room in
                    self?.updateFromRoom(room)
                }
            )
        } catch let failure as StartupFailure {
            // Handle startup failures with proper metrics
            switch failure {
            case let .token(error, metrics):
                startupMetrics = metrics
                state = .idle
                updateStartupState(.failed(.token(error), metrics))
                options.onError?(error)
                throw error

            case let .room(error, metrics):
                startupMetrics = metrics
                state = .idle
                updateStartupState(.failed(.room(error), metrics))
                options.onError?(error)
                if LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission() {
                    options.onError?(ConversationError.localNetworkPermissionRequired)
                }
                throw error

            case let .agentTimeout(metrics):
                startupMetrics = metrics
                state = .idle
                updateStartupState(.failed(.agentTimeout, metrics))
                options.onError?(.agentTimeout)
                throw ConversationError.agentTimeout

            case let .conversationInit(error, metrics):
                startupMetrics = metrics
                state = .idle
                updateStartupState(.failed(.conversationInit(error), metrics))
                options.onError?(error)
                throw error
            }
        }

        state = .active(.init(agentId: result.agentId))
        startupMetrics = result.metrics
        updateStartupState(.active(CallInfo(agentId: result.agentId), result.metrics))

        // Apply pending mute state if user called setMuted during connection
        if let pendingMute = pendingMuteState {
            pendingMuteState = nil
            if let room = connectionManager.room {
                do {
                    try await room.localParticipant.setMicrophone(enabled: !pendingMute)
                    isMuted = pendingMute
                } catch {
                    logger.warning("Failed to apply pending mute state", context: ["error": "\(error)"])
                }
            }
        }

        options.onAgentReady?()

        startRoomObservers()
        startProtocolEventLoop()
    }

    /// Extract agent ID from authentication configuration for state tracking
    private func extractAgentId(from auth: ElevenLabsConfiguration) -> String {
        switch auth.authSource {
        case let .publicAgentId(id):
            id
        case .conversationToken, .customTokenProvider:
            "unknown" // We don't have access to the agent ID in these cases
        }
    }

    /// End and clean up.
    /// Can be called during connection phase to cancel, or during active conversation to end.
    public func endConversation() async {
        // Allow ending during both active and connecting states
        guard state.isActive || state == .connecting else { return }
        guard let connectionManager = resolvedConnectionManager() else {
            // No connection manager yet, just reset state
            if state == .connecting {
                state = .idle
                cleanupPreviousConversation()
            }
            return
        }

        // Disconnect synchronously to ensure clean state
        await connectionManager.disconnect()

        state = .ended(reason: .userEnded)
        cleanupPreviousConversation()

        // Call user's onDisconnect callback if provided
        options.onDisconnect?(.user)
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
        if state.isActive {
            guard let room = resolvedConnectionManager()?.room else {
                throw ConversationError.notConnected
            }
            do {
                try await room.localParticipant.setMicrophone(enabled: !muted)
                isMuted = muted
                pendingMuteState = nil
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
    private var cachedConnectionManager: (any ConnectionManaging)?
    var options: ConversationOptions

    var speakingTimer: Task<Void, Never>?
    private var roomChangesTask: Task<Void, Never>?
    private var protocolEventsDelegate: RoomDelegate?

    private func resolvedConnectionManager() -> (any ConnectionManaging)? {
        cachedConnectionManager
    }

    private func resolveDependencyProvider() async -> any ConversationDependencyProvider {
        if let provider = dependencyProvider {
            return provider
        }

        if let dependenciesTask {
            let deps = await dependenciesTask.value
            dependencyProvider = deps
            // Note: errorHandler setup is handled when connectionManager is retrieved
            return deps
        }

        guard let dependencyProvider else {
            logger.error("Conversation dependency provider not configured")
            fatalError("Conversation dependency provider not configured")
        }
        return dependencyProvider
    }

    private func normalizeConversationError(
        _ error: Error,
        default defaultError: (Error) -> ConversationError
    ) -> ConversationError {
        if let conversationError = error as? ConversationError {
            return conversationError
        }
        return defaultError(error)
    }

    private func updateStartupState(_ newState: ConversationStartupState) {
        startupState = newState
        options.onStartupStateChange?(newState)
    }

    private func resetFlags() {
        // Don't reset isMuted - it should reflect actual room state
        agentState = .listening
        pendingToolCalls.removeAll()
        mcpToolCalls.removeAll()
        mcpConnectionStatus = nil
        conversationMetadata = nil
        startupMetrics = nil
        latestAudioAlignment = nil
        latestAudioEvent = nil
    }

    /// Clean up state from any previous conversation to ensure a fresh start.
    /// This method ensures that each new conversation starts with a clean slate,
    /// preventing any state leakage between conversations when using new Room objects.
    private func cleanupPreviousConversation() {
        // Cancel any ongoing tasks and reset references immediately
        roomChangesTask?.cancel()
        roomChangesTask = nil

        speakingTimer?.cancel()
        speakingTimer = nil

        protocolEventsDelegate = nil

        // Clear conversation state
        messages.removeAll()
        pendingToolCalls.removeAll()
        mcpToolCalls.removeAll()
        mcpConnectionStatus = nil
        conversationMetadata = nil
        currentStreamingMessage = nil

        // Reset agent state
        agentState = .listening
        isMuted = true // Start muted, will be updated based on actual room state

        startupState = .idle
        startupMetrics = nil

        lastAgentEventId = nil
        lastFeedbackSubmittedEventId = nil
        audioManager?.cleanup()
        options.onCanSendFeedbackChange?(false)
        latestAudioEvent = nil

        logger.debug("Previous conversation state cleaned up for fresh Room", context: activeContext)
    }

    private func startRoomObservers() {
        guard let connectionManager = resolvedConnectionManager(),
              connectionManager.shouldObserveRoomConnection,
              let room = connectionManager.room else { return }
        roomChangesTask?.cancel()
        roomChangesTask = Task { [weak self] in
            guard let self else { return }

            // Add ourselves as room delegate to monitor speaking state
            room.add(delegate: self)

            // Monitor existing remote participants
            for participant in room.remoteParticipants.values {
                participant.add(delegate: self)
            }

            updateFromRoom(room)
        }
    }

    private func updateFromRoom(_ room: Room) {
        // Connection state mapping
        switch room.connectionState {
        case .connected, .reconnecting:
            if state == .connecting { state = .active(.init(agentId: state.activeAgentId ?? "")) }
        case .disconnected:
            if state.isActive {
                state = .ended(reason: .remoteDisconnected)
                cleanupPreviousConversation()

                // Call user's onDisconnect callback if provided
                options.onDisconnect?(.agent)
            }
        default: break
        }

        // Audio/Video toggles
        isMuted = !room.localParticipant.isMicrophoneEnabled()
    }

    private func startProtocolEventLoop() {
        guard let connectionManager = resolvedConnectionManager(),
              let room = connectionManager.room
        else {
            return
        }

        // Set up delegate to listen for data events
        // Delegate is stored in protocolEventsDelegate and will be cleaned up in cleanupPreviousConversation
        let delegate = ConversationDataDelegate { [weak self] data in
            self?.handleIncomingData(data)
        }
        protocolEventsDelegate = delegate
        room.add(delegate: delegate)
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
    func _testing_setConnectionManager(_ manager: any ConnectionManaging) {
        cachedConnectionManager = manager
    }

    /// Processes incoming raw data from the network.
    /// - Note: This is nonisolated to allow heavy JSON parsing on background threads.
    private nonisolated func handleIncomingData(_ data: Data) {
        do {
            if let event = try EventParser.parseIncomingEvent(from: data) {
                Task { @MainActor in
                    await handleIncomingEvent(event)
                }
            }
        } catch {
            logger.error("Failed to parse incoming event", context: ["error": "\(error)"])
            logger.debug("Incoming raw data bytes", context: ["bytes": "\(data.count)"])
        }
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
        guard let connectionManager = resolvedConnectionManager(), connectionManager.room != nil else {
            throw ConversationError.notConnected
        }

        // Serialization happens off the main actor automatically
        let data = try EventSerializer.serializeOutgoingEvent(event)

        do {
            let options = DataPublishOptions(reliable: true)
            try await connectionManager.publish(data: data, options: options)
        } catch ConnectionManagerError.roomUnavailable {
            throw ConversationError.notConnected
        } catch {
            throw error
        }
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

    private func appendTentativeAgent(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .agent,
                content: text,
                timestamp: Date()
            )
        )
    }
}

// swiftlint:enable file_length type_body_length

// MARK: - RoomDelegate

extension Conversation {
    public nonisolated func room(
        _: Room, participant: Participant, didUpdateIsSpeaking isSpeaking: Bool
    ) {
        if participant is RemoteParticipant {
            Task { @MainActor in
                if isSpeaking {
                    // Immediately switch to speaking and cancel any pending timeout
                    self.speakingTimer?.cancel()
                    self.agentState = .speaking
                } else {
                    // Add timeout before switching to listening to handle natural speech gaps
                    self.scheduleBackToListening(delay: 1.0) // 1 second delay for natural gaps
                }
            }
        }
    }

    public nonisolated func room(_: Room, participantDidJoin participant: RemoteParticipant) {
        participant.add(delegate: self)
    }
}

/// Thread-safe delegate for handling conversation data.
/// Uses an actor to avoid @unchecked Sendable.
private actor ConversationDataActor {
    private let onData: @Sendable (Data) -> Void

    init(onData: @escaping @Sendable (Data) -> Void) {
        self.onData = onData
    }

    func handleData(_ data: Data) {
        onData(data)
    }
}

private final class ConversationDataDelegate: RoomDelegate {
    private let actor: ConversationDataActor

    init(onData: @escaping @Sendable (Data) -> Void) {
        actor = ConversationDataActor(onData: onData)
    }

    nonisolated func room(
        _: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String,
        encryptionType _: EncryptionType
    ) {
        Task {
            await actor.handleData(data)
        }
    }
}

extension Conversation: ParticipantDelegate {
    public nonisolated func participant(
        _ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool
    ) {
        if participant is RemoteParticipant {
            Task { @MainActor in
                if isSpeaking {
                    // Immediately switch to speaking and cancel any pending timeout
                    self.speakingTimer?.cancel()
                    self.agentState = .speaking
                } else {
                    // Add timeout before switching to listening to handle natural speech gaps
                    self.scheduleBackToListening(delay: 1.0) // 1 second delay for natural gaps
                }
            }
        }
    }
}
