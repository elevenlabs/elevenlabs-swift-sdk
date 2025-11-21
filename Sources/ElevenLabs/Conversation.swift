//
//  Conversation.swift
//  ElevenLabs
//
//  Refactored from AppViewModel.swift into a headless SDK surface.
//

import AVFoundation
import Combine
import Foundation
import LiveKit

@MainActor
public final class Conversation: ObservableObject, RoomDelegate {
    // MARK: - Public State

    @Published public private(set) var state: ConversationState = .idle
    @Published public private(set) var startupState: ConversationStartupState = .idle
    @Published public private(set) var startupMetrics: ConversationStartupMetrics?
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var agentState: AgentState = .listening
    @Published public private(set) var isMuted: Bool = true // Start as true, will be updated based on actual state

    /// Stream of client tool calls that need to be executed by the app
    @Published public private(set) var pendingToolCalls: [ClientToolCallEvent] = []

    /// Conversation metadata including conversation ID, received when the conversation is initialized
    @Published public private(set) var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent
    @Published public private(set) var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations
    @Published public private(set) var mcpConnectionStatus: MCPConnectionStatusEvent?

    /// Latest audio alignment payload emitted by the agent.
    @Published public private(set) var latestAudioAlignment: AudioAlignment?

    /// Latest audio event emitted by the agent.
    @Published public private(set) var latestAudioEvent: AudioEvent?

    // Device lists (optional to expose; keep `internal` if you don't want them public)
    @Published public private(set) var audioDevices: [AudioDevice] = AudioManager.shared
        .inputDevices
    @Published public private(set) var selectedAudioDeviceID: String = AudioManager.shared
        .inputDevice.deviceId

    /// Track the current streaming message for chat response parts
    private var currentStreamingMessage: Message?
    private var lastAgentEventId: Int?
    private var lastFeedbackSubmittedEventId: Int?
    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private var shouldAbortRetries = false

    // Audio tracks for advanced use cases
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
        observeDeviceChanges()
    }

    init(
        dependencyProvider: any ConversationDependencyProvider,
        options: ConversationOptions = .default
    ) {
        self.dependencyProvider = dependencyProvider
        dependenciesTask = nil
        self.options = options
        observeDeviceChanges()
    }

    deinit {
        AudioManager.shared.onDeviceUpdate = nil
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

        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        // Resolve dependencies early to ensure we can clean up properly
        let provider = await resolveDependencyProvider()
        let connectionManager = provider.connectionManager
        let tokenService = provider.tokenService

        // Ensure any existing room is disconnected and cleaned up before creating a new one
        await connectionManager.disconnect()
        cleanupPreviousConversation()

        state = .connecting
        self.options = options
        updateStartupState(.resolvingToken)

        await applyAudioPipelineConfiguration()
        options.onCanSendFeedbackChange?(false)

        connectionManager.errorHandler = provider.errorHandler

        // Acquire token / connection details
        let tokenFetchStart = Date()
        print("[ElevenLabs-Timing] Fetching token...")
        let connDetails: TokenService.ConnectionDetails
        do {
            connDetails = try await tokenService.fetchConnectionDetails(configuration: auth)
            metrics.tokenFetch = Date().timeIntervalSince(tokenFetchStart)
        } catch let error as TokenError {
            metrics.tokenFetch = Date().timeIntervalSince(tokenFetchStart)
            metrics.total = Date().timeIntervalSince(startTime)
            let conversationError: ConversationError = switch error {
            case .authenticationFailed:
                .authenticationFailed(error.localizedDescription)
            case let .httpError(statusCode):
                .authenticationFailed("HTTP error: \(statusCode)")
            case .invalidURL, .invalidResponse, .invalidTokenResponse:
                .authenticationFailed(error.localizedDescription)
            }
            startupMetrics = metrics
            state = .idle
            updateStartupState(.failed(.token(conversationError), metrics))
            options.onError?(conversationError)
            throw conversationError
        } catch {
            metrics.tokenFetch = Date().timeIntervalSince(tokenFetchStart)
            metrics.total = Date().timeIntervalSince(startTime)
            let conversationError = normalizeConversationError(error) { ConversationError.connectionFailed($0) }
            startupMetrics = metrics
            state = .idle
            updateStartupState(.failed(.token(conversationError), metrics))
            options.onError?(conversationError)
            throw conversationError
        }

        updateStartupState(.connectingRoom)

        connectionManager.onAgentDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state.isActive {
                    self.state = .ended(reason: .remoteDisconnected)
                    self.cleanupPreviousConversation()
                    self.options.onDisconnect?()
                }
            }
        }

        // Connect room
        let connectionStart = Date()
        print("[ElevenLabs-Timing] Starting room connection...")
        do {
            try await connectionManager.connect(
                details: connDetails,
                enableMic: !options.conversationOverrides.textOnly,
                networkConfiguration: options.networkConfiguration,
                graceTimeout: options.startupConfiguration.agentReadyTimeout
            )
            metrics.roomConnect = Date().timeIntervalSince(connectionStart)

            if let room = connectionManager.room {
                updateFromRoom(room)
            }
        } catch {
            metrics.roomConnect = Date().timeIntervalSince(connectionStart)
            metrics.total = Date().timeIntervalSince(startTime)
            let conversationError = normalizeConversationError(error) { ConversationError.connectionFailed($0) }
            startupMetrics = metrics
            state = .idle
            updateStartupState(.failed(.room(conversationError), metrics))
            options.onError?(conversationError)
            if LocalNetworkPermissionMonitor.shared.shouldSuggestLocalNetworkPermission() {
                options.onError?(ConversationError.localNetworkPermissionRequired)
            }
            throw conversationError
        }

        updateStartupState(.waitingForAgent(timeout: options.startupConfiguration.agentReadyTimeout))

        let agentOutcome = await connectionManager.waitForAgentReady(
            timeout: options.startupConfiguration.agentReadyTimeout
        )

        let agentReport: ConversationAgentReadyReport
        switch agentOutcome {
        case let .success(detail):
            metrics.agentReady = detail.elapsed
            metrics.agentReadyViaGraceTimeout = detail.viaGraceTimeout
            agentReport = ConversationAgentReadyReport(
                elapsed: detail.elapsed,
                viaGraceTimeout: detail.viaGraceTimeout,
                timedOut: false
            )
        case let .timedOut(elapsed):
            metrics.agentReady = elapsed
            metrics.agentReadyTimedOut = true
            agentReport = ConversationAgentReadyReport(
                elapsed: elapsed,
                viaGraceTimeout: false,
                timedOut: true
            )
            if options.startupConfiguration.failIfAgentNotReady {
                metrics.total = Date().timeIntervalSince(startTime)
                startupMetrics = metrics
                state = .idle
                updateStartupState(.failed(.agentTimeout, metrics))
                options.onError?(.agentTimeout)
                throw ConversationError.agentTimeout
            }
        }

        updateStartupState(.agentReady(agentReport))

        let bufferMilliseconds = await determineOptimalBuffer()
        if bufferMilliseconds > 0 {
            metrics.agentReadyBuffer = bufferMilliseconds / 1000
            print(
                "[ElevenLabs-Timing] Adding \(Int(bufferMilliseconds))ms buffer for agent conversation handler readiness..."
            )
            try? await Task.sleep(nanoseconds: UInt64(bufferMilliseconds * 1_000_000))
        }

        do {
            try await sendConversationInitWithRetry(
                config: options.toConversationConfig(),
                metrics: &metrics
            )
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            startupMetrics = metrics
            state = .idle
            let conversationError = normalizeConversationError(error) { ConversationError.connectionFailed($0) }
            updateStartupState(.failed(.conversationInit(conversationError), metrics))
            options.onError?(conversationError)
            throw conversationError
        }

        state = .active(.init(agentId: extractAgentId(from: auth)))
        metrics.total = Date().timeIntervalSince(startTime)
        startupMetrics = metrics
        updateStartupState(.active(CallInfo(agentId: extractAgentId(from: auth)), metrics))
        options.onAgentReady?()

        // Wire up streams
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
    public func endConversation() async {
        shouldAbortRetries = true
        guard state.isActive else { return }
        guard let connectionManager = resolvedConnectionManager() else { return }
        await connectionManager.disconnect()
        state = .ended(reason: .userEnded)
        cleanupPreviousConversation()

        // Call user's onDisconnect callback if provided
        options.onDisconnect?()
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
        guard state.isActive else { throw ConversationError.notConnected }
        guard let room = resolvedConnectionManager()?.room else { throw ConversationError.notConnected }
        do {
            try await room.localParticipant.setMicrophone(enabled: !muted)
            isMuted = muted
        } catch {
            throw ConversationError.microphoneToggleFailed(error)
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
    private var options: ConversationOptions

    private var speakingTimer: Task<Void, Never>?
    private var roomChangesTask: Task<Void, Never>?
    private var protocolEventsTask: Task<Void, Never>?

    private func resolvedConnectionManager() -> (any ConnectionManaging)? {
        dependencyProvider?.connectionManager
    }

    private func resolveDependencyProvider() async -> any ConversationDependencyProvider {
        if let provider = dependencyProvider {
            return provider
        }

        if let dependenciesTask {
            let deps = await dependenciesTask.value
            dependencyProvider = deps
            deps.connectionManager.errorHandler = deps.errorHandler
            return deps
        }

        guard let dependencyProvider else {
            fatalError("Conversation dependency provider not configured")
        }
        return dependencyProvider
    }

    private func applyAudioPipelineConfiguration() async {
        let audioManager = AudioManager.shared

        let config = options.audioConfiguration

        if let mode = config?.microphoneMuteMode {
            try? audioManager.set(microphoneMuteMode: mode)
        }

        if let prepared = config?.recordingAlwaysPrepared {
            try? await audioManager.setRecordingAlwaysPreparedMode(prepared)
        }

        if let bypass = config?.voiceProcessingBypassed {
            audioManager.isVoiceProcessingBypassed = bypass
        }

        if let agc = config?.voiceProcessingAGCEnabled {
            audioManager.isVoiceProcessingAGCEnabled = agc
        }

        let needsSpeechHandler = (config?.onSpeechActivity != nil) || (options.onSpeechActivity != nil)

        if needsSpeechHandler {
            if !audioSpeechHandlerInstalled {
                previousSpeechActivityHandler = audioManager.onMutedSpeechActivity
                audioSpeechHandlerInstalled = true
            }
            audioManager.onMutedSpeechActivity = { [weak self] _, event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let handler = options.audioConfiguration?.onSpeechActivity {
                        handler(event)
                    }
                    if let handler = options.onSpeechActivity {
                        handler(event)
                    }
                }
            }
        } else if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
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
        // Cancel any ongoing tasks
        roomChangesTask?.cancel()
        protocolEventsTask?.cancel()
        speakingTimer?.cancel()

        // Reset task references
        roomChangesTask = nil
        protocolEventsTask = nil
        speakingTimer = nil

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
        if audioSpeechHandlerInstalled {
            AudioManager.shared.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
        options.onCanSendFeedbackChange?(false)
        latestAudioEvent = nil

        print("[ElevenLabs] Previous conversation state cleaned up for fresh Room")
    }

    private func observeDeviceChanges() {
        do {
            try AudioManager.shared.set(microphoneMuteMode: .inputMixer)
        } catch {
            // ignore: we have no error handler public API yet
        }

        Task {
            do {
                try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
            } catch {
                // ignore: we have no error handler public API yet
            }
        }

        AudioManager.shared.onDeviceUpdate = { [weak self] _ in
            Task { @MainActor in
                self?.audioDevices = AudioManager.shared.inputDevices
                self?.selectedAudioDeviceID = AudioManager.shared.defaultInputDevice.deviceId
            }
        }
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
                options.onDisconnect?()
            }
        default: break
        }

        // Audio/Video toggles
        isMuted = !room.localParticipant.isMicrophoneEnabled()
    }

    private func startProtocolEventLoop() {
        guard let connectionManager = resolvedConnectionManager() else {
            return
        }
        protocolEventsTask?.cancel()
        protocolEventsTask = Task { [weak self] in
            guard let self else {
                return
            }

            let room = connectionManager.room

            // Set up our own delegate to listen for data
            let delegate = ConversationDataDelegate { [weak self] data in
                Task { @MainActor in
                    await self?.handleIncomingData(data)
                }
            }
            room?.add(delegate: delegate)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
        }
    }

    private func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case let .userTranscript(e):
            appendUserTranscript(e.transcript)
            options.onUserTranscript?(e.transcript, e.eventId)

        case .tentativeAgentResponse:
            // Don't change agent state - let voice activity detection handle it
            break

        case let .agentResponse(e):
            appendAgentMessage(e.response)
            lastAgentEventId = e.eventId
            options.onAgentResponse?(e.response, e.eventId)
            if lastFeedbackSubmittedEventId.map({ e.eventId > $0 }) ?? true {
                options.onCanSendFeedbackChange?(true)
            }

        case let .agentResponseCorrection(correction):
            // Handle agent response corrections
            options.onAgentResponseCorrection?(correction.originalAgentResponse, correction.correctedAgentResponse, correction.eventId)

        case let .agentChatResponsePart(e):
            handleAgentChatResponsePart(e)

        case let .audio(audioEvent):
            latestAudioEvent = audioEvent
            latestAudioAlignment = audioEvent.alignment
            if let alignment = audioEvent.alignment {
                options.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            // Only interruption should force listening state - immediately, no timeout
            speakingTimer?.cancel()
            agentState = .listening
            options.onInterruption?(interruptionEvent.eventId)
            options.onCanSendFeedbackChange?(false)

        case let .conversationMetadata(metadata):
            // Store the conversation metadata for public access
            conversationMetadata = metadata
            options.onConversationMetadata?(metadata)

        case let .ping(p):
            // Respond to ping with pong
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case let .clientToolCall(toolCall):
            // Add to pending tool calls for the app to handle
            options.onUnhandledClientToolCall?(toolCall)
            pendingToolCalls.append(toolCall)

        case let .vadScore(vad):
            // VAD scores are available in the event stream
            options.onVadScore?(vad.vadScore)

        case let .agentToolResponse(toolResponse):
            // Agent tool response is available in the event stream
            agentState = .listening

            if toolResponse.toolName == "end_call" {
                Task {
                    await endConversation()
                }
            }
            options.onAgentToolResponse?(toolResponse)

        case let .agentToolRequest(toolRequest):
            // Forward agent tool request to consumer
            // Switch to thinking while the agent performs the tool call
            agentState = .thinking
            options.onAgentToolRequest?(toolRequest)

        case .tentativeUserTranscript:
            // Tentative user transcript (in-progress transcription)
            break

        case let .mcpToolCall(toolCall):
            // Update or append MCP tool call based on toolCallId
            if let index = mcpToolCalls.firstIndex(where: { $0.toolCallId == toolCall.toolCallId }) {
                mcpToolCalls[index] = toolCall
            } else {
                mcpToolCalls.append(toolCall)
            }

        case let .mcpConnectionStatus(status):
            // Update MCP connection status
            mcpConnectionStatus = status

        case .asrInitiationMetadata:
            // ASR initiation metadata is available in the event stream
            break

        case .error:
            // Error events are available in the event stream
            break
        }
    }

    // MARK: - Testing Hooks

    @MainActor
    func _testing_handleIncomingEvent(_ event: IncomingEvent) async {
        await handleIncomingEvent(event)
    }

    func _testing_setState(_ newState: ConversationState) {
        state = newState
    }

    private func handleIncomingData(_ data: Data) async {
        guard dependencyProvider != nil else { return }
        do {
            if let event = try EventParser.parseIncomingEvent(from: data) {
                await handleIncomingEvent(event)
            }
        } catch {
            print("❌ [Conversation] Failed to parse incoming event: \(error)")
            if let dataString = String(data: data, encoding: .utf8) {
                print("❌ [Conversation] Raw data: \(dataString)")
            } else {
                print("❌ [Conversation] Raw data (non-UTF8): \(data.count) bytes")
            }
        }
    }

    private func scheduleBackToListening(delay: TimeInterval = 0.5) {
        speakingTimer?.cancel()
        speakingTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled {
                self.agentState = .listening
            }
        }
    }

    private func publish(_ event: OutgoingEvent) async throws {
        guard let connectionManager = resolvedConnectionManager(), connectionManager.room != nil else {
            throw ConversationError.notConnected
        }

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

    private func sendConversationInit(config: ConversationConfig) async throws {
        let initStart = Date()
        let initEvent = ConversationInitEvent(config: config)
        try await publish(.conversationInit(initEvent))
        print(
            "[ElevenLabs-Timing] Conversation init sent in \(Date().timeIntervalSince(initStart))s")
    }

    /// Determine optimal buffer time based on agent readiness pattern
    /// Different agents need different buffer times for conversation processing readiness
    private func determineOptimalBuffer() async -> TimeInterval {
        guard let room = resolvedConnectionManager()?.room else { return 150.0 } // Default buffer if no room

        // Check if we have any remote participants
        guard !room.remoteParticipants.isEmpty else {
            print("[ElevenLabs-Timing] No remote participants found, using longer buffer")
            return 200.0 // Longer wait if no agent detected
        }

        // For now, we'll use a moderate buffer that should work for most cases
        // This is based on empirical observation that first messages arrive ~2-4s after conversation init
        // But we don't want to wait that long, so we'll use a compromise
        let buffer: TimeInterval = 150.0 // 150ms compromise between speed and reliability

        print("[ElevenLabs-Timing] Determined optimal buffer: \(Int(buffer))ms")
        return buffer
    }

    /// Wait for the system to be fully ready for conversation initialization
    /// Uses state-based detection instead of arbitrary delays
    private func waitForSystemReady(timeout: TimeInterval = 1.5) async -> Bool {
        let startTime = Date()
        let pollInterval: UInt64 = 50_000_000 // 50ms in nanoseconds
        let maxAttempts = Int(timeout * 1000 / 50) // Convert timeout to number of 50ms attempts

        print("[ElevenLabs-Timing] Checking system readiness (state-based detection)...")

        for attempt in 1 ... maxAttempts {
            // Check if we've exceeded timeout
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > timeout {
                print(
                    "[ElevenLabs-Timing] System readiness timeout after \(String(format: "%.3f", elapsed))s"
                )
                return false
            }

            // Get room reference
            guard let room = resolvedConnectionManager()?.room else {
                print("[ElevenLabs-Timing] Attempt \(attempt): No room available")
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }

            // Check 1: Room connection state
            guard room.connectionState == .connected else {
                print(
                    "[ElevenLabs-Timing] Attempt \(attempt): Room not connected (\(room.connectionState))"
                )
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }

            // Check 2: Agent participant present
            guard !room.remoteParticipants.isEmpty else {
                print("[ElevenLabs-Timing] Attempt \(attempt): No remote participants")
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }

            // Check 3: Agent has published audio tracks (indicates full readiness)
            var agentHasAudioTrack = false
            for participant in room.remoteParticipants.values {
                if !participant.audioTracks.isEmpty {
                    agentHasAudioTrack = true
                    break
                }
            }

            guard agentHasAudioTrack else {
                print("[ElevenLabs-Timing] Attempt \(attempt): Agent has no published audio tracks")
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }

            // Check 4: Data channel ready (test by ensuring we can publish)
            // We'll assume if room is connected and agent is present with tracks, data channel is ready
            // This is a reasonable assumption since LiveKit handles data channel setup automatically

            print(
                "[ElevenLabs-Timing] ✅ System ready after \(String(format: "%.3f", elapsed))s (attempt \(attempt))"
            )
            print("[ElevenLabs-Timing]   - Room: connected")
            print("[ElevenLabs-Timing]   - Remote participants: \(room.remoteParticipants.count)")
            print("[ElevenLabs-Timing]   - Agent audio tracks: confirmed")

            return true
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print(
            "[ElevenLabs-Timing] System readiness check exhausted after \(String(format: "%.3f", elapsed))s"
        )
        return false
    }

    private func sendConversationInitWithRetry(
        config: ConversationConfig,
        metrics: inout ConversationStartupMetrics
    ) async throws {
        let delays = options.startupConfiguration.initRetryDelays.isEmpty
            ? [0]
            : options.startupConfiguration.initRetryDelays

        self.shouldAbortRetries = false
        for (index, delay) in delays.enumerated() {
            let attemptNumber = index + 1
            metrics.conversationInitAttempts = attemptNumber
            updateStartupState(.sendingConversationInit(attempt: attemptNumber))

            if delay > 0 {
                print("[Retry] Attempt \(attemptNumber) delay: \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
            }

            if shouldAbortRetries {
                print("[Retry] Aborting retry loop after sleep")
                throw CancellationError()
            }

            let attemptStart = Date()
            do {
                try await sendConversationInit(config: config)
                metrics.conversationInit = Date().timeIntervalSince(attemptStart)
                print("[Retry] ✅ Conversation init succeeded on attempt \(attemptNumber)")
                return
            } catch {
                metrics.conversationInit = Date().timeIntervalSince(attemptStart)
                print("[Retry] ❌ Attempt \(attemptNumber) failed: \(error.localizedDescription)")
                if attemptNumber == delays.count {
                    print("[Retry] ❌ All attempts exhausted, conversation init failed")
                    throw error
                }
            }
        }
    }

    // MARK: - Message Helpers

    private func appendLocalMessage(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: text,
                timestamp: Date()
            )
        )
    }

    private func appendAgentMessage(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .agent,
                content: text,
                timestamp: Date()
            )
        )
    }

    private func appendUserTranscript(_ text: String) {
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

    private func handleAgentChatResponsePart(_ event: AgentChatResponsePartEvent) {
        switch event.type {
        case .start:
            let newMessage = Message(
                id: UUID().uuidString,
                role: .agent,
                content: event.text,
                timestamp: Date()
            )
            currentStreamingMessage = newMessage
            messages.append(newMessage)

        case .delta:
            guard let streamingMessage = currentStreamingMessage else {
                handleAgentChatResponsePart(AgentChatResponsePartEvent(text: event.text, type: .start))
                return
            }

            messages.removeAll { $0.id == streamingMessage.id }
            let updatedContent = streamingMessage.content + event.text
            let updatedMessage = Message(
                id: streamingMessage.id,
                role: .agent,
                content: updatedContent,
                timestamp: streamingMessage.timestamp
            )
            currentStreamingMessage = updatedMessage
            messages.append(updatedMessage)

        case .stop:
            if let streamingMessage = currentStreamingMessage {
                if !event.text.isEmpty {
                    messages.removeAll { $0.id == streamingMessage.id }
                    let finalContent = streamingMessage.content + event.text
                    let finalMessage = Message(
                        id: streamingMessage.id,
                        role: .agent,
                        content: finalContent,
                        timestamp: streamingMessage.timestamp
                    )
                    messages.append(finalMessage)
                }
            }
            currentStreamingMessage = nil
        }
    }
}

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

// MARK: - ParticipantDelegate

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

// MARK: - Simple Data Delegate

private final class ConversationDataDelegate: RoomDelegate, @unchecked Sendable {
    private let onData: (Data) -> Void

    init(onData: @escaping (Data) -> Void) {
        self.onData = onData
    }

    func room(
        _: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String,
        encryptionType _: EncryptionType
    ) {
        onData(data)
    }
}

// MARK: - Public Models

public enum ConversationState: Equatable, Sendable {
    case idle
    case connecting
    case active(CallInfo)
    case ended(reason: EndReason)
    case error(ConversationError)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }

    var activeAgentId: String? {
        if case let .active(info) = self { return info.agentId }
        return nil
    }
}

public struct CallInfo: Equatable, Sendable {
    public let agentId: String
}

public enum EndReason: Equatable, Sendable {
    case userEnded
    case agentNotConnected
    case remoteDisconnected
}

/// Simple chat message model.
public struct Message: Identifiable, Sendable {
    public let id: String
    public let role: Role
    public let content: String
    public let timestamp: Date

    public enum Role: Sendable {
        case user
        case agent
    }
}

// MARK: - Startup Diagnostics

public struct ConversationStartupMetrics: Sendable, Equatable {
    public var total: TimeInterval?
    public var tokenFetch: TimeInterval?
    public var roomConnect: TimeInterval?
    public var agentReady: TimeInterval?
    public var agentReadyViaGraceTimeout: Bool
    public var agentReadyTimedOut: Bool
    public var agentReadyBuffer: TimeInterval?
    public var conversationInit: TimeInterval?
    public var conversationInitAttempts: Int

    public init(
        total: TimeInterval? = nil,
        tokenFetch: TimeInterval? = nil,
        roomConnect: TimeInterval? = nil,
        agentReady: TimeInterval? = nil,
        agentReadyViaGraceTimeout: Bool = false,
        agentReadyTimedOut: Bool = false,
        agentReadyBuffer: TimeInterval? = nil,
        conversationInit: TimeInterval? = nil,
        conversationInitAttempts: Int = 0
    ) {
        self.total = total
        self.tokenFetch = tokenFetch
        self.roomConnect = roomConnect
        self.agentReady = agentReady
        self.agentReadyViaGraceTimeout = agentReadyViaGraceTimeout
        self.agentReadyTimedOut = agentReadyTimedOut
        self.agentReadyBuffer = agentReadyBuffer
        self.conversationInit = conversationInit
        self.conversationInitAttempts = conversationInitAttempts
    }
}

public struct ConversationAgentReadyReport: Sendable, Equatable {
    public let elapsed: TimeInterval
    public let viaGraceTimeout: Bool
    public let timedOut: Bool

    public init(elapsed: TimeInterval, viaGraceTimeout: Bool, timedOut: Bool) {
        self.elapsed = elapsed
        self.viaGraceTimeout = viaGraceTimeout
        self.timedOut = timedOut
    }
}

public enum ConversationStartupFailure: Sendable, Equatable {
    case token(ConversationError)
    case room(ConversationError)
    case agentTimeout
    case conversationInit(ConversationError)
}

public enum ConversationStartupState: Sendable, Equatable {
    case idle
    case resolvingToken
    case connectingRoom
    case waitingForAgent(timeout: TimeInterval)
    case agentReady(ConversationAgentReadyReport)
    case sendingConversationInit(attempt: Int)
    case active(CallInfo, ConversationStartupMetrics)
    case failed(ConversationStartupFailure, ConversationStartupMetrics)
}

public struct ConversationStartupConfiguration: Sendable, Equatable {
    public var agentReadyTimeout: TimeInterval
    public var initRetryDelays: [TimeInterval]
    public var failIfAgentNotReady: Bool

    public init(
        agentReadyTimeout: TimeInterval = 3.0,
        initRetryDelays: [TimeInterval] = [0, 0.2, 0.5],
        failIfAgentNotReady: Bool = false
    ) {
        self.agentReadyTimeout = agentReadyTimeout
        self.initRetryDelays = initRetryDelays
        self.failIfAgentNotReady = failIfAgentNotReady
    }

    public static let `default` = ConversationStartupConfiguration()
}

// MARK: - Options & Errors

public struct ConversationOptions: Sendable {
    public var conversationOverrides: ConversationOverrides
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable
    public var userId: String?

    /// Called when the agent is ready and the conversation can begin
    public var onAgentReady: (@Sendable () -> Void)?

    /// Called when the agent disconnects or the conversation ends
    public var onDisconnect: (@Sendable () -> Void)?

    /// Called whenever the startup state transitions
    public var onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)?

    /// Controls timings and retry behavior for the initialization handshake
    public var startupConfiguration: ConversationStartupConfiguration

    /// Controls microphone pipeline behaviour and VAD callbacks.
    public var audioConfiguration: AudioPipelineConfiguration?

    /// Controls LiveKit peer connection behaviour, including ICE policies.
    public var networkConfiguration: LiveKitNetworkConfiguration

    /// Called when a startup-related error occurs
    public var onError: (@Sendable (ConversationError) -> Void)?

    /// Called when LiveKit detects speech activity while muted.
    public var onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)?

    /// Called for each agent response (finalized transcript) with its event identifier.
    public var onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called when an agent response is corrected.
    public var onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)?

    /// Called for each user transcript event emitted by the server.
    public var onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)?

    /// Called whenever conversation metadata is received.
    public var onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)?

    /// Called when the agent issues a tool response.
    public var onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)?

    /// Called when the agent requests a tool execution.
    public var onAgentToolRequest: (@Sendable (AgentToolRequestEvent) -> Void)?

    /// Called when the agent detects an interruption.
    public var onInterruption: (@Sendable (_ eventId: Int) -> Void)?

    /// Called whenever the server emits a VAD score.
    public var onVadScore: (@Sendable (_ score: Double) -> Void)?

    /// Called when the agent emits audio alignment metadata for spoken words.
    public var onAudioAlignment: (@Sendable (AudioAlignment) -> Void)?

    /// Called when the client should enable/disable feedback UI.
    public var onCanSendFeedbackChange: (@Sendable (Bool) -> Void)?

    /// Called when an unhandled client tool call is received.
    public var onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)?

    public init(
        conversationOverrides: ConversationOverrides = .init(),
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil,
        onStartupStateChange: (@Sendable (ConversationStartupState) -> Void)? = nil,
        startupConfiguration: ConversationStartupConfiguration = .default,
        audioConfiguration: AudioPipelineConfiguration? = nil,
        networkConfiguration: LiveKitNetworkConfiguration = .default,
        onError: (@Sendable (ConversationError) -> Void)? = nil,
        onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)? = nil,
        onAgentResponse: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onAgentResponseCorrection: (@Sendable (_ original: String, _ corrected: String, _ eventId: Int) -> Void)? = nil,
        onUserTranscript: (@Sendable (_ text: String, _ eventId: Int) -> Void)? = nil,
        onConversationMetadata: (@Sendable (ConversationMetadataEvent) -> Void)? = nil,
        onAgentToolResponse: (@Sendable (AgentToolResponseEvent) -> Void)? = nil,
        onAgentToolRequest: (@Sendable (AgentToolRequestEvent) -> Void)? = nil,
        onInterruption: (@Sendable (_ eventId: Int) -> Void)? = nil,
        onVadScore: (@Sendable (_ score: Double) -> Void)? = nil,
        onAudioAlignment: (@Sendable (AudioAlignment) -> Void)? = nil,
        onCanSendFeedbackChange: (@Sendable (Bool) -> Void)? = nil,
        onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? = nil
    ) {
        self.conversationOverrides = conversationOverrides
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.onAgentReady = onAgentReady
        self.onDisconnect = onDisconnect
        self.onStartupStateChange = onStartupStateChange
        self.startupConfiguration = startupConfiguration
        self.audioConfiguration = audioConfiguration
        self.networkConfiguration = networkConfiguration
        self.onError = onError
        self.onSpeechActivity = onSpeechActivity
        self.onAgentResponse = onAgentResponse
        self.onAgentResponseCorrection = onAgentResponseCorrection
        self.onUserTranscript = onUserTranscript
        self.onConversationMetadata = onConversationMetadata
        self.onAgentToolResponse = onAgentToolResponse
        self.onAgentToolRequest = onAgentToolRequest
        self.onInterruption = onInterruption
        self.onVadScore = onVadScore
        self.onAudioAlignment = onAudioAlignment
        self.onCanSendFeedbackChange = onCanSendFeedbackChange
        self.onUnhandledClientToolCall = onUnhandledClientToolCall
    }

    public static let `default` = ConversationOptions()
}

extension ConversationOptions {
    func toConversationConfig() -> ConversationConfig {
        ConversationConfig(
            agentOverrides: agentOverrides,
            ttsOverrides: ttsOverrides,
            conversationOverrides: conversationOverrides,
            customLlmExtraBody: customLlmExtraBody,
            dynamicVariables: dynamicVariables,
            userId: userId,
            onAgentReady: onAgentReady,
            onDisconnect: onDisconnect,
            onStartupStateChange: onStartupStateChange,
            startupConfiguration: startupConfiguration,
            audioConfiguration: audioConfiguration,
            networkConfiguration: networkConfiguration,
            onError: onError,
            onSpeechActivity: onSpeechActivity
        )
    }
}

public enum ConversationError: LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyActive
    case connectionFailed(String) // Store error description instead of Error for Equatable
    case authenticationFailed(String)
    case agentTimeout
    case microphoneToggleFailed(String) // Store error description instead of Error for Equatable
    case localNetworkPermissionRequired

    // Helper methods to create errors with Error types
    public static func connectionFailed(_ error: Error) -> ConversationError {
        .connectionFailed(error.localizedDescription)
    }

    public static func microphoneToggleFailed(_ error: Error) -> ConversationError {
        .microphoneToggleFailed(error.localizedDescription)
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Conversation is not connected."
        case .alreadyActive: "Conversation is already active."
        case let .connectionFailed(description): "Connection failed: \(description)"
        case let .authenticationFailed(msg): "Authentication failed: \(msg)"
        case .agentTimeout: "Agent did not join in time."
        case let .microphoneToggleFailed(description): "Failed to toggle microphone: \(description)"
        case .localNetworkPermissionRequired: "Local Network permission is required."
        }
    }
}
