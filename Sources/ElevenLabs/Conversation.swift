//
//  Conversation.swift
//  ElevenLabs
//
//  Refactored from AppViewModel.swift into a headless SDK surface.
//

import Foundation
import Combine
import LiveKit
import AVFoundation

@MainActor
public final class Conversation: ObservableObject {

    // MARK: - Public State

    @Published public private(set) var state: ConversationState = .idle
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var agentState: AgentState = .listening
    @Published public private(set) var isMuted: Bool = false
    
    /// Stream of client tool calls that need to be executed by the app
    @Published public private(set) var pendingToolCalls: [ClientToolCallEvent] = []

    // Device lists (optional to expose; keep `internal` if you don't want them public)
    @Published public private(set) var audioDevices: [AudioDevice] = AudioManager.shared.inputDevices
    @Published public private(set) var selectedAudioDeviceID: String = AudioManager.shared.inputDevice.deviceId
    
    // Audio tracks for advanced use cases
    public var inputTrack: LocalAudioTrack? {
        guard let deps, let room = deps.connectionManager.room else { return nil }
        return room.localParticipant.firstAudioPublication?.track as? LocalAudioTrack
    }
    
    public var agentAudioTrack: RemoteAudioTrack? {
        guard let deps, let room = deps.connectionManager.room else { return nil }
        // Find the first remote participant (agent) with audio track
        return room.remoteParticipants.values.first?.firstAudioPublication?.track as? RemoteAudioTrack
    }

    // MARK: - Init

    internal init(dependencies: Task<Dependencies, Never>,
                  options: ConversationOptions = .default) {
        self._depsTask = dependencies
        self.options = options
        observeDeviceChanges()
    }

    deinit {
        AudioManager.shared.onDeviceUpdate = nil
    }

    // MARK: - Public API

    /// Start a conversation with an agent using agent ID.
    public func startConversation(with agentId: String,
                                  options: ConversationOptions = .default) async throws {
        let authConfig = ElevenLabsConfiguration.publicAgent(id: agentId)
        try await startConversation(auth: authConfig, options: options)
    }
    
    /// Start a conversation using authentication configuration.
    public func startConversation(auth: ElevenLabsConfiguration,
                                  options: ConversationOptions = .default) async throws {
        guard state == .idle || state.isEnded else {
            throw ConversationError.alreadyActive
        }

        state = .connecting
        self.options = options

        // Resolve deps
        let deps = await _depsTask.value
        self.deps = deps

        // Acquire token / connection details
        let connDetails = try await deps.tokenService.fetchConnectionDetails(configuration: auth)
        
        // Connect room
        try await deps.connectionManager.connect(details: connDetails,
                                                 enableMic: !options.conversationOverrides.textOnly)

        // Wire up streams
        startRoomObservers()
        startProtocolEventLoop()

        // Send conversation init to ElevenLabs
        try await sendConversationInit(config: options.toConversationConfig())

        // Extract agent ID for state tracking
        let agentId = extractAgentId(from: auth)
        state = .active(.init(agentId: agentId))
        
        // Monitor for agent joining (optional diagnostic)
        Task {
            try await Task.sleep(nanoseconds: 3_000_000_000) // Wait 3 seconds
            guard let room = deps.connectionManager.room else { return }
            if room.remoteParticipants.isEmpty {
                print("⚠️ ElevenLabs SDK: No agent joined the room. Check agent ID: \(agentId)")
            }
        }
    }
    
    /// Extract agent ID from authentication configuration for state tracking
    private func extractAgentId(from auth: ElevenLabsConfiguration) -> String {
        switch auth.authSource {
        case .publicAgentId(let id):
            return id
        case .conversationToken, .customTokenProvider:
            return "unknown" // We don't have access to the agent ID in these cases
        }
    }

    /// End and clean up.
    public func endConversation() async {
        guard state.isActive else { return }
        await deps?.connectionManager.disconnect()
        state = .ended(reason: .userEnded)
        resetFlags()
    }

    /// Send a text message to the agent.
    public func sendMessage(_ text: String) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        appendLocalMessage(text)
    }

    /// Toggle / set microphone
    public func toggleMute() async throws {
        try await setMuted(!isMuted)
    }

    public func setMuted(_ muted: Bool) async throws {
        guard let room = deps?.connectionManager.room else { return }
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
    public func sendToolResult(for toolCallId: String, result: Any, isError: Bool = false) async throws {
        guard state.isActive else { throw ConversationError.notConnected }
        let toolResult = try ClientToolResultEvent(toolCallId: toolCallId, result: result, isError: isError)
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

    private func resetFlags() {
        isMuted = false
        agentState = .listening
        pendingToolCalls.removeAll()
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
            // For now, just update once - in a real implementation this would listen to room events
            updateFromRoom(room)
        }
    }

    private func updateFromRoom(_ room: Room) {
        // Connection state mapping
        switch room.connectionState {
        case .connected, .reconnecting:
            if state == .connecting { state = .active(.init(agentId: state.activeAgentId ?? "")) }
        case .disconnected:
            if state.isActive { state = .ended(reason: .remoteDisconnected) }
        default: break
        }

        // Audio/Video toggles
        isMuted = !room.localParticipant.isMicrophoneEnabled()
    }

    private func startProtocolEventLoop() {
        guard let deps else { 
            print("❌ SDK: No deps available for protocol event loop")
            return 
        }
        print("🔄 SDK: Starting protocol event loop...")
        protocolEventsTask?.cancel()
        protocolEventsTask = Task { [weak self] in
            guard let self else { 
                print("❌ SDK: Self is nil in protocol event loop")
                return 
            }
            
            // Use DataChannelReceiver directly instead of ConnectionManager stream
            guard let room = deps.connectionManager.room else {
                print("❌ SDK: No room available for DataChannelReceiver")
                return
            }
            
            if #available(macOS 11.0, iOS 14.0, *) {
                let dataChannelReceiver = DataChannelReceiver(room: room)
                let eventStream = await dataChannelReceiver.events()
                for await event in eventStream {
                    await handleIncomingEvent(event)
                }
            } else {
                // Fallback to original ConnectionManager approach for older OS versions
                let stream = deps.connectionManager.dataEventsStream()
                for await data in stream {
                    await handleIncomingData(data)
                }
            }
        }
    }

    private func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case .userTranscript(let e):
            agentState = .listening
            appendUserTranscript(e.transcript)

        case .tentativeAgentResponse(let e):
            agentState = .speaking
            scheduleBackToListening()
            appendTentativeAgent(e.tentativeResponse)

        case .agentResponse(let e):
            agentState = .speaking
            scheduleBackToListening()
            appendAgentMessage(e.response)

        case .agentResponseCorrection(_):
            // Handle agent response corrections
            break

        case .audio:
            agentState = .speaking
            scheduleBackToListening(delay: 0.8)

        case .interruption:
            agentState = .listening

        case .conversationMetadata:
            agentState = .listening

        case .ping(let p):
            // Respond to ping with pong
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case .clientToolCall(let toolCall):
            print("🔨 SDK: Received client tool call: \(toolCall.toolName) (ID: \(toolCall.toolCallId)) - expects response: \(toolCall.expectsResponse)")
            print("🔨 SDK: Current pendingToolCalls count before append: \(pendingToolCalls.count)")
            // Add to pending tool calls for the app to handle
            pendingToolCalls.append(toolCall)
            print("🔨 SDK: Added to pending tool calls. Total pending: \(pendingToolCalls.count)")
            print("🔨 SDK: pendingToolCalls array contents: \(pendingToolCalls.map { "\($0.toolName):\($0.toolCallId)" })")
        }
    }

    private func handleIncomingData(_ data: Data) async {
        guard deps != nil else { return }
        do {
            print("📦 SDK: Received incoming data, parsing...")
            if let event = try EventParser.parseIncomingEvent(from: data) {
                print("✅ SDK: Parsed event: \(event)")
                switch event {
                case .userTranscript(let e):
                    print("🎤 SDK: Received userTranscript event: '\(e.transcript)'")
                    agentState = .listening
                    // optional: update transcription state
                    appendUserTranscript(e.transcript)

                case .tentativeAgentResponse(let e):
                    print("💭 SDK: Received tentativeAgentResponse event: '\(e.tentativeResponse)'")
                    agentState = .speaking
                    scheduleBackToListening()
                    appendTentativeAgent(e.tentativeResponse)

                case .agentResponse(let e):
                    print("🤖 SDK: Received agentResponse event: '\(e.response)'")
                    agentState = .speaking
                    scheduleBackToListening()
                    appendAgentMessage(e.response)

                case .agentResponseCorrection(_):
                    // Handle agent response corrections
                    break

                case .audio:
                    agentState = .speaking
                    scheduleBackToListening(delay: 0.8)

                case .interruption:
                    agentState = .listening

                case .conversationMetadata:
                    agentState = .listening

                case .ping(let p):
                    // respond
                    let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
                    try await publish(pong)

                case .clientToolCall(_):
                    // surface to client via Combine/stream later; omitted here
                    break
                }
            } else {
                print("⚠️ SDK: Failed to parse event from data")
            }
        } catch {
            print("❌ SDK: Error parsing incoming data: \(error)")
            // swallow parsing errors for now or surface via a delegate/stream
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
            print("❌ SDK: Cannot publish - no room connection")
            throw ConversationError.notConnected
        }
        
        print("📤 SDK: Publishing event: \(event)")
        let data = try EventSerializer.serializeOutgoingEvent(event)
        print("📤 SDK: Serialized event data size: \(data.count) bytes")
        
        do {
            let options = DataPublishOptions(reliable: true)
            print("📤 SDK: Publishing with options: reliable=\(options.reliable), topic='\(options.topic ?? "default")'")
            try await room.localParticipant.publish(data: data, options: options)
            print("✅ SDK: Successfully published event")
        } catch {
            print("❌ SDK: Failed to publish event: \(error)")
            throw error
        }
    }

    private func sendConversationInit(config: ConversationConfig) async throws {
        print("🚀 SDK: Sending conversation init with config: \(config)")
        let initEvent = ConversationInitEvent(config: config)
        print("🚀 SDK: Created init event: \(initEvent)")
        try await publish(.conversationInit(initEvent))
        print("✅ SDK: Conversation init sent successfully")
    }

    // MARK: - Message Helpers

    private func appendLocalMessage(_ text: String) {
        print("🏠 SDK: Appending local/user message: '\(text)'")
        messages.append(
            Message(id: UUID().uuidString,
                    role: .user,
                    content: text,
                    timestamp: Date())
        )
        print("🏠 SDK: Total messages after local append: \(messages.count)")
    }

    private func appendAgentMessage(_ text: String) {
        messages.append(
            Message(id: UUID().uuidString,
                    role: .agent,
                    content: text,
                    timestamp: Date())
        )
    }

    private func appendUserTranscript(_ text: String) {
        // If you want partial transcript merging, do it here
        messages.append(
            Message(id: UUID().uuidString,
                    role: .user,
                    content: text,
                    timestamp: Date())
        )
    }

    private func appendTentativeAgent(_ text: String) {
        print("💭 SDK: Appending tentative agent message: '\(text)'")
        // Could present as typing indicator; here we just append
        messages.append(
            Message(id: UUID().uuidString,
                    role: .agent,
                    content: text,
                    timestamp: Date())
        )
        print("💭 SDK: Total messages after tentative append: \(messages.count)")
    }
}

// MARK: - Public Models

public enum ConversationState: Equatable, Sendable {
    case idle
    case connecting
    case active(CallInfo)
    case ended(reason: EndReason)
    case error(ConversationError)

    var isActive: Bool {
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
    public var customLlmExtraBody: [String: String]? // Simplified to be Sendable
    public var dynamicVariables: [String: String]? // Simplified to be Sendable

    public init(conversationOverrides: ConversationOverrides = .init(),
                agentOverrides: AgentOverrides? = nil,
                ttsOverrides: TTSOverrides? = nil,
                customLlmExtraBody: [String: String]? = nil,
                dynamicVariables: [String: String]? = nil) {
        self.conversationOverrides = conversationOverrides
        self.agentOverrides = agentOverrides
        self.ttsOverrides = ttsOverrides
        self.customLlmExtraBody = customLlmExtraBody
        self.dynamicVariables = dynamicVariables
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
            dynamicVariables: dynamicVariables
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

    // Helper methods to create errors with Error types
    public static func connectionFailed(_ error: Error) -> ConversationError {
        .connectionFailed(error.localizedDescription)
    }
    
    public static func microphoneToggleFailed(_ error: Error) -> ConversationError {
        .microphoneToggleFailed(error.localizedDescription)
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected:                      "Conversation is not connected."
        case .alreadyActive:                     "Conversation is already active."
        case .connectionFailed(let description): "Connection failed: \(description)"
        case .authenticationFailed(let msg):     "Authentication failed: \(msg)"
        case .agentTimeout:                      "Agent did not join in time."
        case .microphoneToggleFailed(let description): "Failed to toggle microphone: \(description)"
        }
    }
}
