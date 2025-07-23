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

    // Device lists (optional to expose; keep `internal` if you don’t want them public)
    @Published public private(set) var audioDevices: [AudioDevice] = AudioManager.shared.inputDevices
    @Published public private(set) var selectedAudioDeviceID: String = AudioManager.shared.inputDevice.deviceId

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

    /// Start a conversation with an agent.
    public func startConversation(with agentId: String,
                                  options: ConversationOptions = .default) async throws {
        guard state == .idle || state == .ended else {
            throw ConversationError.alreadyActive
        }

        state = .connecting
        self.options = options

        // Resolve deps
        let deps = await _depsTask.value
        self.deps = deps

        // Acquire token / connection details
        let connDetails = try await deps.tokenService.fetchConnectionDetails(agentId: agentId,
                                                                             overrides: options)
        // Connect room
        try await deps.connectionManager.connect(details: connDetails,
                                                 enableMic: !options.conversationOverrides.textOnly)

        // Wire up streams
        startRoomObservers()
        startProtocolEventLoop()

        // Send conversation init to ElevenLabs
        try await sendConversationInit(config: options.toConversationConfig())

        state = .active(.init(agentId: agentId))
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
        guard let deps else { return }
        roomChangesTask?.cancel()
        roomChangesTask = Task { [weak self] in
            guard let self, let changes = deps.connectionManager.room?.changes else { return }
            for await _ in changes {
                guard let room = deps.connectionManager.room else { return }
                updateFromRoom(room)
            }
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
        guard let deps else { return }
        protocolEventsTask?.cancel()
        protocolEventsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await deps.connectionManager.dataEventsStream()
            for await data in stream {
                await handleIncomingData(data)
            }
        }
    }

    private func handleIncomingData(_ data: Data) async {
        guard let deps else { return }
        do {
            if let event = try deps.eventParser.parseIncomingEvent(from: data) {
                switch event {
                case .userTranscript(let e):
                    agentState = .listening
                    // optional: update transcription state
                    appendUserTranscript(e.transcript)

                case .tentativeAgentResponse(let e):
                    agentState = .speaking
                    scheduleBackToListening()
                    appendTentativeAgent(e.tentativeResponse)

                case .agentResponse(let e):
                    agentState = .speaking
                    scheduleBackToListening()
                    appendAgentMessage(e.response)

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

                case .clientToolCall(let t):
                    // surface to client via Combine/stream later; omitted here
                    break
                }
            }
        } catch {
            // swallow parsing errors for now or surface via a delegate/stream
        }
    }

    private func scheduleBackToListening(delay: TimeInterval = 0.5) {
        speakingTimer?.cancel()
        speakingTimer = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled {
                self.agentState = .listening
            }
        }
    }

    private func publish(_ event: OutgoingEvent) async throws {
        guard let deps, let room = deps.connectionManager.room else {
            throw ConversationError.notConnected
        }
        let data = try deps.eventSerializer.serializeOutgoingEvent(event)
        try await room.localParticipant.publish(data: data,
                                                options: DataPublishOptions(reliable: true))
    }

    private func sendConversationInit(config: ConversationConfig) async throws {
        let initEvent = ConversationInitEvent(config: config)
        try await publish(.conversationInit(initEvent))
    }

    // MARK: - Message Helpers

    private func appendLocalMessage(_ text: String) {
        messages.append(
            Message(id: UUID().uuidString,
                    role: .user,
                    content: text,
                    timestamp: Date())
        )
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
        // Could present as typing indicator; here we just append
        messages.append(
            Message(id: UUID().uuidString,
                    role: .agent,
                    content: text,
                    timestamp: Date())
        )
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

public enum AgentState: Sendable {
    case listening
    case speaking
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
    public var customLlmExtraBody: [String: Any]?
    public var dynamicVariables: [String: Any]?

    public init(conversationOverrides: ConversationOverrides = .init(),
                agentOverrides: AgentOverrides? = nil,
                ttsOverrides: TTSOverrides? = nil,
                customLlmExtraBody: [String: Any]? = nil,
                dynamicVariables: [String: Any]? = nil) {
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

public enum ConversationError: LocalizedError, Sendable {
    case notConnected
    case alreadyActive
    case connectionFailed(Error)
    case authenticationFailed(String)
    case agentTimeout
    case microphoneToggleFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notConnected:                    "Conversation is not connected."
        case .alreadyActive:                   "Conversation is already active."
        case .connectionFailed(let err):       "Connection failed: \(err.localizedDescription)"
        case .authenticationFailed(let msg):   "Authentication failed: \(msg)"
        case .agentTimeout:                    "Agent did not join in time."
        case .microphoneToggleFailed(let err): "Failed to toggle microphone: \(err.localizedDescription)"
        }
    }
}
