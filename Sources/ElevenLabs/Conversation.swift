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
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var agentState: AgentState = .listening
    @Published public private(set) var isMuted: Bool = false

    /// Stream of client tool calls that need to be executed by the app
    @Published public private(set) var pendingToolCalls: [ClientToolCallEvent] = []

    // Device lists (optional to expose; keep `internal` if you don't want them public)
    @Published public private(set) var audioDevices: [AudioDevice] = AudioManager.shared
        .inputDevices
    @Published public private(set) var selectedAudioDeviceID: String = AudioManager.shared
        .inputDevice.deviceId

    // Audio tracks for advanced use cases
    public var inputTrack: LocalAudioTrack? {
        guard let deps, let room = deps.connectionManager.room else { return nil }
        return room.localParticipant.firstAudioPublication?.track as? LocalAudioTrack
    }

    public var agentAudioTrack: RemoteAudioTrack? {
        guard let deps, let room = deps.connectionManager.room else { return nil }
        // Find the first remote participant (agent) with audio track
        return room.remoteParticipants.values.first?.firstAudioPublication?.track
            as? RemoteAudioTrack
    }

    // MARK: - Init

    init(
        dependencies: Task<Dependencies, Never>,
        options: ConversationOptions = .default
    ) {
        _depsTask = dependencies
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
        print("[ElevenLabs-Timing] Starting conversation at \(startTime)")

        // Resolve deps early to ensure we can clean up properly
        let deps = await _depsTask.value
        self.deps = deps

        // Ensure any existing room is disconnected and cleaned up before creating a new one
        // This guarantees a fresh Room object for each conversation
        await deps.connectionManager.disconnect()
        
        // Clean up any existing state from previous conversations
        cleanupPreviousConversation()

        state = .connecting
        self.options = options

        // Acquire token / connection details
        let tokenFetchStart = Date()
        print("[ElevenLabs-Timing] Fetching token...")
        let connDetails: TokenService.ConnectionDetails
        do {
            connDetails = try await deps.tokenService.fetchConnectionDetails(configuration: auth)
        } catch let error as TokenError {
            // Convert TokenError to ConversationError
            switch error {
            case .authenticationFailed:
                throw ConversationError.authenticationFailed(error.localizedDescription)
            case let .httpError(statusCode):
                throw ConversationError.authenticationFailed("HTTP error: \(statusCode)")
            case .invalidURL, .invalidResponse, .invalidTokenResponse:
                throw ConversationError.authenticationFailed(error.localizedDescription)
            }
        }

        print("[ElevenLabs-Timing] Token fetched in \(Date().timeIntervalSince(tokenFetchStart))s")

        deps.connectionManager.onAgentReady = { [weak self, auth, options] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                let agentReadyTime = Date()
                print(
                    "[ElevenLabs-Timing] Agent ready callback triggered at \(Date().timeIntervalSince(startTime))s from start"
                )

                // Ensure room connection is fully complete before sending init
                // This prevents race condition where agent is ready but we can't publish data yet
                let roomCheckStart = Date()
                if let room = deps.connectionManager.room, room.connectionState == .connected {
                    // Room is ready, proceed immediately
                    print("[ElevenLabs-Timing] Room fully connected (check took \(Date().timeIntervalSince(roomCheckStart))s)")
                } else {
                    print("[ElevenLabs-Timing] Room not fully connected yet, waiting...")
                    
                    // Device-specific optimization: skip or reduce wait
                    let isDevice: Bool
                    #if targetEnvironment(simulator)
                    isDevice = false
                    #else
                    isDevice = true
                    #endif
                    
                    // On device, use shorter wait or skip entirely
                    let waitTime: UInt64 = isDevice ? 20_000_000 : 100_000_000  // 20ms on device, 100ms on simulator
                    
                    let waitStart = Date()
                    try? await Task.sleep(nanoseconds: waitTime)
                    print("[ElevenLabs-Timing] Room wait completed in \(Date().timeIntervalSince(waitStart))s (device: \(isDevice))")
                    
                    if let room = deps.connectionManager.room, room.connectionState == .connected {
                        print("[ElevenLabs-Timing] Room connected after wait")
                    } else {
                        print(
                            "[ElevenLabs-Timing] ⚠️ Room still not connected, proceeding anyway...")
                    }
                }

                print("[ElevenLabs-Timing] Starting buffer determination...")
                let bufferStart = Date()
                
                // Add buffer based on whether agent was already there (fast path) or just joined
                let buffer = await self.determineOptimalBuffer()
                print("[ElevenLabs-Timing] Buffer determination took \(Date().timeIntervalSince(bufferStart))s")
                
                if buffer > 0 {
                    print(
                        "[ElevenLabs-Timing] Adding \(Int(buffer))ms buffer for agent conversation handler readiness..."
                    )
                    let bufferSleepStart = Date()
                    try? await Task.sleep(nanoseconds: UInt64(buffer * 1_000_000))
                    print("[ElevenLabs-Timing] Buffer sleep completed in \(Date().timeIntervalSince(bufferSleepStart))s")
                } else {
                    print(
                        "[ElevenLabs-Timing] No buffer needed, sending conversation init immediately"
                    )
                }

                // Cancel any existing init attempt
                self.conversationInitTask?.cancel()
                
                print("[ElevenLabs-Timing] Creating conversation init task...")
                let initTaskStart = Date()
                self.conversationInitTask = Task {
                    await self.sendConversationInitWithRetry(config: options.toConversationConfig())
                }
                await self.conversationInitTask?.value
                print("[ElevenLabs-Timing] Conversation init task completed in \(Date().timeIntervalSince(initTaskStart))s")
                
                // flip to .active once conversation init is sent
                self.state = .active(.init(agentId: self.extractAgentId(from: auth)))
                print("[ElevenLabs] State changed to active")
                
                let totalCallbackTime = Date().timeIntervalSince(agentReadyTime)
                print(
                    "[ElevenLabs-Timing] Agent ready callback completed in \(totalCallbackTime)s"
                )
                print(
                    "[ElevenLabs-Timing] Total startup time: \(Date().timeIntervalSince(startTime))s"
                )
                
                // Call user's onAgentReady callback if provided
                options.onAgentReady?()
            }
        }

        deps.connectionManager.onAgentDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state.isActive {
                    self.state = .ended(reason: .remoteDisconnected)
                    self.cleanupPreviousConversation()
                    
                    // Call user's onDisconnect callback if provided
                    self.options.onDisconnect?()
                }
            }
        }

        // Connect room
        let connectionStart = Date()
        print("[ElevenLabs-Timing] Starting room connection...")
        do {
            try await deps.connectionManager.connect(
                details: connDetails,
                enableMic: !options.conversationOverrides.textOnly)
            print(
                "[ElevenLabs-Timing] Room connected in \(Date().timeIntervalSince(connectionStart))s"
            )
        } catch {
            // Convert connection errors to ConversationError
            throw ConversationError.connectionFailed(error)
        }

        // Wire up streams
        startRoomObservers()
        startProtocolEventLoop()
    }

    /// Extract agent ID from authentication configuration for state tracking
    private func extractAgentId(from auth: ElevenLabsConfiguration) -> String {
        switch auth.authSource {
        case let .publicAgentId(id):
            return id
        case .conversationToken, .customTokenProvider:
            return "unknown"  // We don't have access to the agent ID in these cases
        }
    }

    /// End and clean up.
    public func endConversation() async {
        guard state.isActive else { return }
        await deps?.connectionManager.disconnect()
        state = .ended(reason: .userEnded)
        cleanupPreviousConversation()
        
        // Call user's onDisconnect callback if provided
        options.onDisconnect?()
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
        guard let room = deps?.connectionManager.room else { throw ConversationError.notConnected }
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
        let event = OutgoingEvent.feedback(FeedbackEvent(score: score, eventId: eventId))
        try await publish(event)
    }

    /// Send the result of a client tool call back to the agent.
    public func sendToolResult(for toolCallId: String, result: Any, isError: Bool = false)
        async throws
    {
        guard state.isActive else { throw ConversationError.notConnected }
        let toolResult = try ClientToolResultEvent(
            toolCallId: toolCallId, result: result, isError: isError)
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

    private var deps: Dependencies?
    private let _depsTask: Task<Dependencies, Never>
    private var options: ConversationOptions

    private var speakingTimer: Task<Void, Never>?
    private var roomChangesTask: Task<Void, Never>?
    private var protocolEventsTask: Task<Void, Never>?
    private var conversationInitTask: Task<Void, Never>?

    private func resetFlags() {
        isMuted = false
        agentState = .listening
        pendingToolCalls.removeAll()
        conversationInitTask?.cancel()
    }

    /// Clean up state from any previous conversation to ensure a fresh start.
    /// This method ensures that each new conversation starts with a clean slate,
    /// preventing any state leakage between conversations when using new Room objects.
    private func cleanupPreviousConversation() {
        // Cancel any ongoing tasks
        roomChangesTask?.cancel()
        protocolEventsTask?.cancel()
        conversationInitTask?.cancel()
        speakingTimer?.cancel()
        
        // Reset task references
        roomChangesTask = nil
        protocolEventsTask = nil
        conversationInitTask = nil
        speakingTimer = nil
        
        // Clear conversation state
        messages.removeAll()
        pendingToolCalls.removeAll()
        
        // Reset agent state
        agentState = .listening
        isMuted = false
        
        print("[ElevenLabs] Previous conversation state cleaned up for fresh Room")
    }

    private func observeDeviceChanges() {
        do {
            try AudioManager.shared.set(microphoneMuteMode: .inputMixer)
            try AudioManager.shared.setRecordingAlwaysPreparedMode(true)
        } catch {
            // ignore: we have no error handler public API yet
        }

        AudioManager.shared.onDeviceUpdate = { [weak self] _ in
            Task { @MainActor in
                self?.audioDevices = AudioManager.shared.inputDevices
                self?.selectedAudioDeviceID = AudioManager.shared.defaultInputDevice.deviceId
            }
        }
    }

    private func startRoomObservers() {
        guard let deps, let room = deps.connectionManager.room else { return }
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
        guard let deps else {
            return
        }
        protocolEventsTask?.cancel()
        protocolEventsTask = Task { [weak self] in
            guard let self else {
                return
            }

            let room = deps.connectionManager.room

            // Set up our own delegate to listen for data
            let delegate = ConversationDataDelegate { [weak self] data in
                Task { @MainActor in
                    await self?.handleIncomingData(data)
                }
            }
            room?.add(delegate: delegate)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            }
        }
    }

    private func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case let .userTranscript(e):
            // Don't change agent state - let voice activity detection handle it
            appendUserTranscript(e.transcript)

        case let .tentativeAgentResponse(e):
            // Don't change agent state - let voice activity detection handle it
            break

        case let .agentResponse(e):
            // Don't change agent state - let voice activity detection handle it
            appendAgentMessage(e.response)

        case .agentResponseCorrection:
            // Handle agent response corrections
            break

        case .audio:
            // Don't change agent state - let voice activity detection handle it
            break

        case .interruption:
            // Only interruption should force listening state - immediately, no timeout
            speakingTimer?.cancel()
            agentState = .listening

        case .conversationMetadata:
            // Don't change agent state on metadata
            break

        case let .ping(p):
            // Respond to ping with pong
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case let .clientToolCall(toolCall):
            // Add to pending tool calls for the app to handle
            pendingToolCalls.append(toolCall)

        case let .vadScore(vadScoreEvent):
            // VAD scores are available in the event stream
            break
        }
    }

    private func handleIncomingData(_ data: Data) async {
        guard deps != nil else { return }
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
        guard let deps, let room = deps.connectionManager.room else {
            throw ConversationError.notConnected
        }

        let data = try EventSerializer.serializeOutgoingEvent(event)

        do {
            let options = DataPublishOptions(reliable: true)
            try await room.localParticipant.publish(data: data, options: options)
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
        guard let room = deps?.connectionManager.room else { return 50.0 }  // Reduced default buffer
        
        // Check if we have any remote participants
        guard !room.remoteParticipants.isEmpty else {
            print("[ElevenLabs-Timing] No remote participants found, using longer buffer")
            return 100.0  // Reduced from 200ms to 100ms
        }
        
        // Check if running on simulator vs device
        let isSimulator: Bool
        #if targetEnvironment(simulator)
        isSimulator = true
        #else
        isSimulator = false
        #endif
        
        // Use shorter buffer on device since data channel setup can be slower
        // but we don't want to wait too long
        let buffer: TimeInterval = isSimulator ? 150.0 : 50.0
        
        print("[ElevenLabs-Timing] Determined optimal buffer: \(Int(buffer))ms (simulator: \(isSimulator))")
        return buffer
    }

    /// Wait for the system to be fully ready for conversation initialization
    /// Uses state-based detection instead of arbitrary delays
    private func waitForSystemReady(timeout: TimeInterval = 1.5) async -> Bool {
        let startTime = Date()
        let pollInterval: UInt64 = 50_000_000  // 50ms in nanoseconds
        let maxAttempts = Int(timeout * 1000 / 50)  // Convert timeout to number of 50ms attempts

        print("[ElevenLabs-Timing] Checking system readiness (state-based detection)...")

        for attempt in 1...maxAttempts {
            // Check if we've exceeded timeout
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > timeout {
                print(
                    "[ElevenLabs-Timing] System readiness timeout after \(String(format: "%.3f", elapsed))s"
                )
                return false
            }

            // Get room reference
            guard let room = deps?.connectionManager.room else {
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

    private func sendConversationInitWithRetry(config: ConversationConfig, maxAttempts: Int = 3)
        async
    {
        // Check if running on device
        let isDevice: Bool
        #if targetEnvironment(simulator)
        isDevice = false
        #else
        isDevice = true
        #endif
        
        for attempt in 1...maxAttempts {
            // More aggressive delays on device: skip first retry delay entirely
            if attempt > 1 {
                let delay: Double
                if isDevice && attempt == 2 {
                    // On device, skip delay for first retry (attempt 2)
                    delay = 0
                } else {
                    // Reduced delays: 0ms (skipped above), 50ms, 100ms
                    delay = Double(attempt - 2) * 0.05
                }
                
                if delay > 0 {
                    print("[Retry] Attempt \(attempt) of \(maxAttempts), backoff delay: \(delay)s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    print("[Retry] Attempt \(attempt) of \(maxAttempts), no delay (device optimization)")
                }
            } else {
                print("[Retry] Attempt \(attempt) of \(maxAttempts), no delay")
            }

            do {
                try await sendConversationInit(config: config)
                print("[Retry] ✅ Conversation init succeeded on attempt \(attempt)")
                return
            } catch {
                print("[Retry] ❌ Attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == maxAttempts {
                    print("[Retry] ❌ All attempts exhausted, conversation init failed")
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
                timestamp: Date())
        )
    }

    private func appendAgentMessage(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .agent,
                content: text,
                timestamp: Date())
        )
    }

    private func appendUserTranscript(_ text: String) {
        // If you want partial transcript merging, do it here
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: text,
                timestamp: Date())
        )
    }

    private func appendTentativeAgent(_ text: String) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: .agent,
                content: text,
                timestamp: Date())
        )
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
                    self.scheduleBackToListening(delay: 1.0)  // 1 second delay for natural gaps
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
                    self.scheduleBackToListening(delay: 1.0)  // 1 second delay for natural gaps
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
        _: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String
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

// MARK: - Options & Errors

public struct ConversationOptions: Sendable {
    public var conversationOverrides: ConversationOverrides
    public var agentOverrides: AgentOverrides?
    public var ttsOverrides: TTSOverrides?
    public var customLlmExtraBody: [String: String]?  // Simplified to be Sendable
    public var dynamicVariables: [String: String]?  // Simplified to be Sendable
    public var userId: String?
    
    /// Called when the agent is ready and the conversation can begin
    public var onAgentReady: (@Sendable () -> Void)?
    
    /// Called when the agent disconnects or the conversation ends
    public var onDisconnect: (@Sendable () -> Void)?

    public init(
        conversationOverrides: ConversationOverrides = .init(),
        agentOverrides: AgentOverrides? = nil,
        ttsOverrides: TTSOverrides? = nil,
        customLlmExtraBody: [String: String]? = nil,
        dynamicVariables: [String: String]? = nil,
        userId: String? = nil,
        onAgentReady: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil
    ) {
        self.conversationOverrides = conversationOverrides
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
        self.userId = userId
        self.onAgentReady = onAgentReady
        self.onDisconnect = onDisconnect
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
            onDisconnect: onDisconnect
        )
    }
}

public enum ConversationError: LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyActive
    case connectionFailed(String)  // Store error description instead of Error for Equatable
    case authenticationFailed(String)
    case agentTimeout
    case microphoneToggleFailed(String)  // Store error description instead of Error for Equatable

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
        }
    }
}
