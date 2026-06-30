import Combine
import Foundation

// swiftlint:disable file_length type_body_length

/// A single-use conversation session: created `.idle`, connected once, and
/// terminal after it ends. Coordinates the transport (`WebRTCConnectionManager`
/// / `WebSocketConnectionManager`), the protocol parser, and `@Published` UI
/// state.
///
/// Internal: ``ConversationClient`` owns one per session and mirrors its
/// published state, so the public API only ever sees `ConversationClient`.
@MainActor
final class Conversation: ObservableObject {
    // MARK: - Public State

    @Published var state: ConversationState = .idle
    @Published var messages: [Message] = []

    /// Whether the agent is currently speaking, from the transport's
    /// remote-speaking detection. (There is no "listening" state: the agent
    /// always listens.)
    @Published var isAgentSpeaking: Bool = false
    /// Whether the local microphone (input) is muted — distinct from agent
    /// output muting (``isAgentMuted``). Starts `true`; reconciled with the
    /// actual capture state once a voice conversation connects.
    @Published var isMicMuted: Bool = true

    /// Whether the user is speaking while the mic is muted. Only detected for
    /// ``MicrophoneMuteMode/voiceProcessing`` and
    /// ``MicrophoneMuteMode/software(speechThreshold:)``; always `false`
    /// otherwise. Resets on unmute and when the conversation ends.
    @Published var isSpeakingWhileMuted: Bool = false

    /// Whether the agent's audio output (playback) is muted. Independent of
    /// ``isMicMuted``. Defaults to `false` (agent audible).
    @Published var isAgentMuted: Bool = false

    /// Client tool calls awaiting execution or local completion by the app.
    @Published var pendingToolCalls: [ClientToolCallEvent] = []

    /// Server metadata (conversation id, audio formats), set once the init
    /// handshake is acknowledged.
    @Published var conversationMetadata: ConversationMetadataEvent?

    /// MCP tool calls from the agent.
    @Published var mcpToolCalls: [MCPToolCallEvent] = []

    /// Current MCP connection status for all integrations.
    @Published var mcpConnectionStatus: MCPConnectionStatusEvent?

    // MARK: - Audio pipeline state
    //
    // `internal` (not `private`) so the controls in `Conversation+Audio` reach them.

    /// Render-ready audio levels (aggregate + per-band) for the mic input and
    /// agent output. Deliberately **not** `@Published`: they update at audio
    /// cadence and are forwarded by `ConversationClient` into the per-channel
    /// `AudioLevelMonitor`s (which gate the reactive scalar and expose a pollable
    /// snapshot), so they never churn views bound to the session.
    var onInputLevels: ((Float, [Float]) -> Void)?
    var onOutputLevels: ((Float, [Float]) -> Void)?

    /// Mute requested mid-connect, applied once the transport is up.
    var pendingMuteState: Bool?

    /// Audio device management.
    var audioManager: ConversationAudioManager?

    /// Renderers tapping the live tracks to drive ``onInputLevels`` /
    /// ``onOutputLevels``. Created/destroyed as tracks come and go.
    var inputLevelProcessor: AudioLevelProcessor?
    var agentLevelProcessor: AudioLevelProcessor?

    /// Externally-registered audio renderers (see `addAgentAudioRenderer(_:)` /
    /// `addInputAudioRenderer(_:)`). Kept attached across track swaps.
    let agentRendererRegistry = ExternalAudioRendererRegistry()
    let inputRendererRegistry = ExternalAudioRendererRegistry()

    /// Internal logger, accessible from nonisolated contexts.
    nonisolated let logger: any Logging

    // MARK: - Init

    /// Creates a session. With a `nil` `dependencyProvider`, a production
    /// `Dependencies` is built for this conversation; tests inject a provider
    /// that vends mock connection managers. `config` is fixed for the session.
    ///
    /// Audio setup is intentionally deferred to `connect(auth:)`: it activates
    /// the capture engine and triggers the mic-permission prompt.
    init(
        dependencyProvider: (any ConversationDependencyProvider)? = nil,
        config: ConversationConfig = .default,
        callbacks: ConversationCallbacks? = nil
    ) {
        // Built in the @MainActor init body (not a default arg) so no
        // main-actor-isolated value is referenced from a nonisolated context.
        let provider = dependencyProvider ?? Dependencies(logLevel: config.logLevel)
        self.provider = provider
        self.config = config
        self.callbacks = callbacks ?? ConversationCallbacks()
        self.logger = provider.logger
    }

    // MARK: - Lifecycle

    /// Connect this single-use conversation. Throws
    /// ``ConversationError/alreadyActive`` unless `.idle` (it connects exactly
    /// once). `auth` is consumed here so TTL'd tokens stay fresh.
    func connect(auth: ConversationAuth) async throws {
        guard state == .idle else {
            throw ConversationError.alreadyActive
        }

        let provider = self.provider

        // Each transport drives its own startup phases and returns once the
        // init handshake has been sent.
        if config.textOnly {
            try await startTextOnlyConversation(auth: auth, config: config, provider: provider)
        } else {
            try await startVoiceConversation(auth: auth, config: config, provider: provider)
        }

        // Startup may have already ended the session (user ended mid-connect,
        // or the agent dropped); don't override that terminal state.
        guard state.isConnecting else {
            throw CancellationError()
        }

        // Startup completes only when the agent acknowledges the handshake with
        // `conversation_initiation_metadata`. Block until it arrives, bounded by
        // `conversationInitTimeout`; a timeout surfaces as `.initializationTimeout`
        // (distinct from `.agentTimeout`, the voice room-join wait).
        state = .connecting(phase: .waitingForInitData)
        let metadataReceived = await awaitConversationMetadata(
            timeout: config.conversationInitTimeout
        )

        // Teardown while waiting resolves the waiter too; if no longer
        // connecting, it already set the terminal state — don't clobber it.
        guard state.isConnecting else {
            throw CancellationError()
        }
        // A cooperative cancel (e.g. the caller cancelled the start task) breaks
        // the metadata wait; unwind as `CancellationError` rather than a spurious
        // init timeout.
        if Task.isCancelled {
            if let connectionManager = activeConnectionManager {
                await handleStartupCancellation(disconnecting: connectionManager)
            }
            throw CancellationError()
        }
        guard metadataReceived else {
            if let connectionManager = activeConnectionManager {
                await handleStartupFailure(
                    .conversationInit(.initializationTimeout),
                    disconnecting: connectionManager
                )
            }
            throw ConversationError.initializationTimeout
        }

        state = .connected
        callbacks.onAgentReady?()
    }

    /// Suspend until `conversation_initiation_metadata` arrives, `timeout`
    /// elapses, or the surrounding task is cancelled; returns whether the
    /// metadata arrived. Single main-actor waiter resolved exactly once (the
    /// continuation nil-check in `resolveMetadataWaiter` enforces this) by the
    /// event handler, the timeout task, teardown, or cooperative cancellation.
    /// On cancellation it resumes promptly with `false`; `connect` then checks
    /// `Task.isCancelled` and unwinds as `CancellationError`.
    private func awaitConversationMetadata(timeout: TimeInterval) async -> Bool {
        if conversationMetadata != nil { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                metadataContinuation = continuation
                // Cancelled before we suspended: resolve now rather than waiting
                // out the full timeout.
                if Task.isCancelled {
                    resolveMetadataWaiter(false)
                    return
                }
                metadataTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.resolveMetadataWaiter(false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveMetadataWaiter(false) }
        }
    }

    /// Resolve the in-flight metadata waiter (if any) as succeeded. Called from
    /// the event handler when `conversation_initiation_metadata` is received.
    func resumeConversationMetadataWaiter() {
        resolveMetadataWaiter(true)
    }

    /// Resolve the in-flight metadata waiter exactly once and tear down its
    /// timeout task. Idempotent via the continuation nil-check, so the event
    /// handler, timeout, teardown, and cancellation can all call it racelessly
    /// on the main actor. `received` is `true` only when the metadata arrived.
    private func resolveMetadataWaiter(_ received: Bool) {
        metadataTimeoutTask?.cancel()
        metadataTimeoutTask = nil
        guard let pending = metadataContinuation else { return }
        metadataContinuation = nil
        pending.resume(returning: received)
    }

    private func startVoiceConversation(
        auth: ConversationAuth,
        config: ConversationConfig,
        provider: any ConversationDependencyProvider
    ) async throws {
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

        webRTCConnectionManager.onTracksChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshAudioLevelProcessors()
            }
        }

        // Build/configure the audio pipeline (pre-warms the capture engine; see
        // `ConversationAudioManager.configure`).
        if audioManager == nil {
            audioManager = ConversationAudioManager(logger: logger)
        }
        await audioManager?.configure(with: config) { [weak self] speaking in
            Task { @MainActor in self?.isSpeakingWhileMuted = speaking }
        }

        do {
            try await webRTCConnectionManager.connect(
                auth: auth,
                config: config
            )
        } catch let failure as ConversationStartupFailure {
            let committed = await handleStartupFailure(failure, disconnecting: webRTCConnectionManager)
            // If the session was already ended concurrently, the failure was
            // suppressed — surface cancellation rather than a stale failure.
            throw committed ? failure.error : CancellationError()
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: webRTCConnectionManager)
            throw CancellationError()
        }

        await reconcileMicMuteAfterConnect(webRTCConnectionManager)

        // Attach to any tracks already present (mic, and the agent track if it
        // was subscribed before the delegate callback fired).
        refreshAudioLevelProcessors()
    }

    /// Reconcile the published mute flag with the live pipeline once the
    /// transport is up, applying any mute requested mid-connect through the
    /// *active mute mode*. Software mute keeps the capture track open, so the
    /// hardware mic flag is not its source of truth — the software gate is.
    private func reconcileMicMuteAfterConnect(
        _ webRTCConnectionManager: any WebRTCConnectionManaging
    ) async {
        let pendingMute = pendingMuteState
        pendingMuteState = nil
        if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
            if let pendingMute {
                softwareMuteProcessor.setMuted(pendingMute)
            }
            isMicMuted = softwareMuteProcessor.muted
        } else {
            if let pendingMute {
                do {
                    try await webRTCConnectionManager.setMicrophoneMuted(pendingMute)
                } catch {
                    logger.warning("Failed to apply pending mute state", context: ["error": "\(error)"])
                }
            }
            isMicMuted = webRTCConnectionManager.isMicrophoneMuted
        }
    }

    private func startTextOnlyConversation(
        auth: ConversationAuth,
        config: ConversationConfig,
        provider: ConversationDependencyProvider
    ) async throws {
        let connectionManager = provider.webSocketConnectionManager
        await prepareConversationStart(
            auth: auth, config: config,
            connectionManager: connectionManager
        )

        do {
            try await connectionManager.connect(auth: auth, config: config)
        } catch let failure as ConversationStartupFailure {
            let committed = await handleStartupFailure(failure, disconnecting: connectionManager)
            // If the session was already ended concurrently, the failure was
            // suppressed — surface cancellation rather than a stale failure.
            throw committed ? failure.error : CancellationError()
        } catch is CancellationError {
            await handleStartupCancellation(disconnecting: connectionManager)
            throw CancellationError()
        }
    }

    /// End the conversation (also cancels an in-progress connect).
    func endConversation() async {
        await endConversation(reason: .userEnded)
    }

    /// Clear a terminated session back to `.idle`, discarding the transcript,
    /// metadata, and tool/MCP state that ``endConversation()`` deliberately
    /// preserves. Lets a UI dismiss a startup failure or a finished transcript
    /// without immediately starting a new conversation.
    ///
    /// No-op unless the session has terminated (`.ended` or `.startupFailed`);
    /// end a connecting/connected session first.
    func reset() {
        switch state {
        case .ended, .startupFailed:
            break
        case .idle, .connecting, .connected:
            return
        }

        tearDownActiveSession()
        messages = []
        conversationMetadata = nil
        mcpToolCalls = []
        mcpConnectionStatus = nil
        state = .idle
    }

    /// `reason` is the single source of truth for why the session ended; the
    /// coarse ``DisconnectionReason`` handed to `onDisconnect` is derived from it.
    private func endConversation(reason: EndReason) async {
        guard !state.isInactive else { return }
        guard let connectionManager = activeConnectionManager else {
            // No transport yet; just reset.
            if state.isConnecting {
                state = .idle
                tearDownActiveSession()
            }
            return
        }
        state = .ended(reason: reason)

        await connectionManager.disconnect()
        tearDownActiveSession()
        callbacks.onDisconnect?(DisconnectionReason(reason))
    }

    /// Send a text message to the agent.
    func sendMessage(_ text: String) async throws {
        guard state == .connected else {
            throw ConversationError.notConnected
        }
        let event = OutgoingEvent.userMessage(UserMessageEvent(text: text))
        try await publish(event)
        appendMessage(role: .user, content: text)
    }

    /// Interrupt the agent while speaking.
    func interruptAgent() async throws {
        guard state == .connected else { throw ConversationError.notConnected }
        let event = OutgoingEvent.userActivity
        try await publish(event)
    }

    /// Send a silent contextual update to the agent.
    func updateContext(_ context: String) async throws {
        guard state == .connected else { throw ConversationError.notConnected }
        let event = OutgoingEvent.contextualUpdate(ContextualUpdateEvent(text: context))
        try await publish(event)
    }

    /// Send feedback (like/dislike) for an event/message id.
    func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        guard state == .connected else {
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
        guard state == .connected else { throw ConversationError.notConnected }
        let approval = MCPToolApprovalResultEvent(toolCallId: toolCallId, isApproved: isApproved)
        try await publish(.mcpToolApprovalResult(approval))
    }

    /// Send the result of a client tool call back to the agent.
    func sendToolResult(
        for toolCallId: String,
        result: Any,
        isError: Bool = false,
        errorType: ClientToolErrorType? = nil
    )
        async throws
    {
        guard state == .connected else { throw ConversationError.notConnected }
        let toolResult = try ClientToolResultEvent(
            toolCallId: toolCallId,
            result: result,
            isError: isError,
            errorType: errorType
        )
        let event = OutgoingEvent.clientToolResult(toolResult)
        try await publish(event)

        pendingToolCalls.removeAll { $0.toolCallId == toolCallId }
    }

    /// Mark a tool call as completed without sending a result (for tools that don't expect responses).
    func markToolCallCompleted(_ toolCallId: String) {
        pendingToolCalls.removeAll { $0.toolCallId == toolCallId }
    }

    // MARK: - Private

    private let provider: any ConversationDependencyProvider
    private var activeConnectionManager: (any ConnectionManaging)?
    /// `internal` (not `private`) because the audio controls in
    /// `Conversation+Audio` reach the WebRTC transport through it.
    var activeWebRTCConnectionManager: (any WebRTCConnectionManaging)? {
        activeConnectionManager as? any WebRTCConnectionManaging
    }

    let config: ConversationConfig
    let callbacks: ConversationCallbacks

    var speakingTimer: Task<Void, Never>?

    /// In-flight waiter for `conversation_initiation_metadata` during startup.
    private var metadataContinuation: CheckedContinuation<Bool, Never>?

    /// Times out the metadata wait; cancelled when the waiter resolves for any
    /// reason (metadata, teardown, or cooperative cancellation).
    private var metadataTimeoutTask: Task<Void, Never>?

    /// Serializes incoming events through a single consumer so handlers run in
    /// strict arrival order (see `prepareConversationStart`).
    private var eventStreamContinuation: AsyncStream<IncomingEvent>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?

    /// Common preparation shared by voice and text-only startup paths.
    private func prepareConversationStart(
        auth: ConversationAuth,
        config: ConversationConfig,
        connectionManager: any ConnectionManaging
    ) async {
        state = .connecting(phase: .authorizing)

        activeConnectionManager = connectionManager
        // Reset in case the provider reuses a manager instance (e.g. test
        // mocks); a fresh Conversation otherwise starts clean.
        await connectionManager.disconnect()

        // Agent id is only known client-side for public-agent / signed-URL auth;
        // omit it for conversation-token auth rather than logging a placeholder.
        let agentId: String? = switch auth.authSource {
        case let .publicAgentId(id): id
        case let .signedWebSocketURL(_, id): id
        case .conversationToken: nil
        }
        let mode = config.textOnly ? "text-only" : "voice"
        logger.info("Starting \(mode) conversation", context: agentId.map { ["agentId": $0] })

        connectionManager.onStartupPhaseChange = { [weak self] phase in
            self?.state = .connecting(phase: phase)
        }
        // Serialize incoming events through one consumer so handlers run in
        // strict arrival order: yielding is synchronous and ordered, so handlers
        // can't interleave across their `await` points (e.g. ping → pong).
        var continuation: AsyncStream<IncomingEvent>.Continuation!
        let eventStream = AsyncStream<IncomingEvent> { continuation = $0 }
        let streamContinuation: AsyncStream<IncomingEvent>.Continuation = continuation
        eventStreamContinuation = streamContinuation
        eventConsumerTask = Task { @MainActor [weak self, weak connectionManager] in
            for await event in eventStream {
                guard let self else { return }
                guard let connectionManager,
                      activeConnectionManager === connectionManager,
                      !state.isInactive
                else {
                    continue
                }
                await handleIncomingEvent(event)
            }
        }
        connectionManager.onEventReceived = { event in
            streamContinuation.yield(event)
        }
        // Raw wire tap → public `onMessage`. Capture only the (Sendable)
        // callbacks, never `self`, and skip building the string when no
        // consumer is attached so the receive path stays allocation-free.
        connectionManager.onRawMessage = { [callbacks] data, event in
            guard let onMessage = callbacks.onMessage else { return }
            onMessage(Conversation.messageSource(for: event), String(decoding: data, as: UTF8.self))
        }
        connectionManager.onDisconnected = { [weak self] in
            guard let self else { return }
            await endConversation(reason: .remoteDisconnected)
        }
    }

    /// Maps an incoming frame to the `source` value surfaced through
    /// ``ConversationCallbacks/onMessage``: `"user"` for user transcripts,
    /// `"ai"` for everything else (including unknown/unparseable frames).
    private nonisolated static func messageSource(for event: IncomingEvent?) -> String {
        switch event {
        case .userTranscript?, .tentativeUserTranscript?:
            return "user"
        default:
            return "ai"
        }
    }

    /// Move the session into ``ConversationState/startupFailed(_:)`` and fire
    /// `onError`. Returns `false` (leaving state untouched, no `onError`) if the
    /// session was already torn down concurrently, so the caller can surface
    /// cancellation instead of a stale failure.
    @discardableResult
    private func handleStartupFailure(
        _ failure: ConversationStartupFailure,
        disconnecting connectionManager: any ConnectionManaging
    ) async -> Bool {
        cleanupTransientResources()
        await connectionManager.disconnect()

        // Re-check after the `disconnect` suspension: only own the transition
        // while still connecting. No `await` between here and the mutation, so
        // this is race-free on the main actor.
        guard state.isConnecting else { return false }

        state = .startupFailed(failure)
        callbacks.onError?(failure.error)
        return true
    }

    private func handleStartupCancellation(disconnecting connectionManager: any ConnectionManaging) async {
        cleanupTransientResources()
        await connectionManager.disconnect()
        // Don't clobber a terminal state set by a concurrent teardown.
        guard state.isConnecting else { return }
        state = .idle
    }

    /// Tear down operational state when an active session ends.
    /// Preserves user-visible display state (messages, MCP activity, conversation
    /// metadata) so the transcript remains visible until a new conversation is
    /// started.
    private func tearDownActiveSession() {
        cleanupTransientResources()

        pendingToolCalls.removeAll()
    }

    private func cleanupTransientResources() {
        speakingTimer?.cancel()
        speakingTimer = nil
        pendingMuteState = nil

        // Stop draining incoming events; the session is terminal from here.
        eventStreamContinuation?.finish()
        eventStreamContinuation = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil

        // Resolve any in-flight startup metadata waiter so its continuation and
        // timeout task don't leak if the session is torn down mid-wait.
        resolveMetadataWaiter(false)
        isAgentSpeaking = false
        isMicMuted = true
        isAgentMuted = false
        isSpeakingWhileMuted = false

        teardownAudioLevelProcessors()
        audioManager?.cleanup()
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

    // MARK: - Agent speaking state

    func handleRemoteSpeakingUpdate(isSpeaking: Bool) {
        if isSpeaking {
            speakingTimer?.cancel()
            isAgentSpeaking = true
        } else {
            // Fast attack / slow release: LiveKit's energy-based `isSpeaking`
            // toggles off across natural pauses, so hold "speaking" briefly to
            // bridge them rather than flickering. The agent resuming within the
            // window cancels the pending flip.
            scheduleAgentStoppedSpeaking()
        }
    }

    /// How long to hold `isAgentSpeaking` after LiveKit reports the agent
    /// stopped (see `handleRemoteSpeakingUpdate`).
    private static let agentStoppedSpeakingDelay: TimeInterval = 0.5

    private func scheduleAgentStoppedSpeaking() {
        speakingTimer?.cancel()
        speakingTimer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.agentStoppedSpeakingDelay * 1_000_000_000))
                self?.isAgentSpeaking = false
            } catch {
                // Cancelled; nothing to do.
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
