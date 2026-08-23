#if os(iOS)
import Combine
import ElevenLabs
import Foundation
import SwiftUI
import UIKit

@available(iOS 16, macCatalyst 16, *)
@MainActor
final class ChatWidgetViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var input = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var conversationState: ConversationState = .idle
    @Published private(set) var agentState: AgentState = .listening
    @Published private(set) var isMicMuted = false
    @Published private(set) var isSending = false
    /// The session the widget has going, from the moment one is requested —
    /// before its credentials are minted — until it ends or fails. The UI follows
    /// this rather than everything the mode allows.
    @Published private(set) var sessionKind: WidgetSessionKind?
    @Published private(set) var banner: ChatWidgetBanner?
    /// Closes off the transcript once a session is over, and carries the id the
    /// user would quote in a support request.
    @Published private(set) var endedConversation: EndedConversation?

    struct EndedConversation: Equatable {
        let id: String?
        let endedByUser: Bool
    }

    /// All four mirror what the host passes to ``ChatWidget``, so changes land
    /// on the live view model instead of needing a new conversation.
    var mode: WidgetConversationMode
    var conversationConfig: ConversationConfig
    var onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?
    @Published var widgetConfig: ChatWidgetConfig
    let client: ConversationClient
    let audioLevels = OrbAudioLevels()

    /// Tool calls already dispatched, so a re-published snapshot doesn't run them twice.
    private var dispatchedToolCallIds: Set<String> = []
    /// The in-flight startup, so overlapping callers join it instead of racing.
    private var startTask: (kind: WidgetSessionKind, task: Task<Void, Error>)?
    /// Bumped per start, so work outliving a session can tell it went stale.
    private var sessionGeneration = 0
    /// Reset on teardown, so a host keeping it doesn't read a dead session's state.
    weak var controller: ChatWidgetController?
    private var bannerDismissal: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        mode: WidgetConversationMode,
        widgetConfig: ChatWidgetConfig,
        client: ConversationClient,
        conversationConfig: ConversationConfig,
        onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?
    ) {
        self.mode = mode
        self.widgetConfig = widgetConfig
        self.client = client
        self.conversationConfig = conversationConfig
        self.onClientToolCall = onClientToolCall

        // The client is durable across sessions, so every subscription and
        // observer is wired once.
        client.addMicAudioObserver(audioLevels.micMonitor)
        client.addAgentAudioObserver(audioLevels.agentMonitor)

        client.$state.assign(to: &$conversationState)
        client.$state
            .sink { [weak self] in self?.audioLevels.isActive = $0.isConnected }
            .store(in: &cancellables)
        client.$agentState.assign(to: &$agentState)
        client.$isMicMuted.assign(to: &$isMicMuted)
        client.$chatHistory
            .map { $0.compactMap(\.message).filter { !$0.content.isEmpty }.map(ChatMessage.init) }
            .assign(to: &$messages)
        client.$pendingToolCalls
            .combineLatest(client.$state)
            .filter { _, state in state.isConnected }
            .map { calls, _ in calls }
            .sink { [weak self] in self?.dispatchNewToolCalls($0) }
            .store(in: &cancellables)
        // Only a finished session clears the kind: the client rebinds to a fresh
        // conversation on every start, and that publishes `.idle` before it
        // connects, which would wipe the kind of the session just requested.
        client.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case let .ended(reason):
                    sessionKind = nil
                    dismissBanner()
                    endedConversation = EndedConversation(
                        id: client.conversationMetadata?.conversationId,
                        endedByUser: reason == .userEnded
                    )
                case .error:
                    sessionKind = nil
                    // The error itself stays on `conversationState` for the host;
                    // the banner is user-facing copy the host can reword.
                    show(ChatWidgetBanner(strings.conversationFailed))
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// The host can drop the widget mid-call, and nothing else owns the client,
    /// so the session and the microphone would otherwise stay live. The
    /// controller's mirrors freeze on the last value once we stop publishing,
    /// so they are cleared rather than left reading `connected`.
    deinit {
        let client = client
        let controller = controller
        Task { @MainActor in
            await client.endConversation()
            // A replacement widget can attach while this teardown is suspended.
            // The binding is weak, so it is nil only if we were the last one.
            if controller?.binding == nil { controller?.reset() }
        }
    }

    // MARK: - Derived state

    private var strings: ChatWidgetStrings {
        widgetConfig.strings
    }

    var canEndConversation: Bool {
        sessionKind != nil
    }

    var canSend: Bool {
        !isSending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canToggleMicMute: Bool {
        widgetConfig.enableMicMuteControl && sessionKind == .voice && conversationState.isConnected
    }

    var canShowTextInput: Bool {
        mode.supportsTextInput
    }

    var supportsVoice: Bool {
        mode.supportsVoice
    }

    var canStartVoiceConversation: Bool {
        supportsVoice && sessionKind == nil
    }

    var showsTranscript: Bool {
        mode.showsTranscript
    }

    var orbState: ChatOrbState {
        switch conversationState {
        case .idle, .ended, .error: .disconnected
        case .connecting: .connecting
        case .connected:
            switch agentState {
            case .speaking: .speaking
            case .thinking: .thinking
            case .listening: .listening
            }
        }
    }

    // MARK: - Presentation

    func open() {
        setOpen(true)
    }

    func close() {
        setOpen(false)
    }

    func toggleOpen() {
        setOpen(!isOpen)
    }

    /// Every open and close goes through here, including the host's, so the
    /// drawer animates and the keyboard retracts with it either way.
    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if !open {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { isOpen = open }
    }

    // MARK: - Conversation

    func startConversation() {
        Task {
            do {
                try await startConversationAndWait()
            } catch is CancellationError {
                // The user ended the call before it connected.
            } catch {
                show(ChatWidgetBanner(strings.conversationStartFailed))
            }
        }
    }

    /// The SDK connects muted rather than failing when the microphone is off, so
    /// the widget is what tells the user why nobody can hear them.
    private func warnIfMicrophoneUnavailable() {
        guard sessionKind == .voice, MicrophonePermission.isDenied else { return }
        show(ChatWidgetBanner(strings.microphonePermissionDenied, offersSettings: true))
    }

    func startConversationAndWait() async throws {
        try await startConversationAndWait(mode.requestedSessionKind)
    }

    private func startConversationAndWait(_ kind: WidgetSessionKind) async throws {
        // Joining first matters while connecting: returning early there would let
        // a send reach the agent before the session is up. A voice session also
        // carries typed messages, but a text-only one has no microphone to call
        // over, so that pairing can't be joined.
        if let startTask {
            guard startTask.kind == .voice || kind == .textOnly else {
                throw ConversationError.alreadyStarted
            }
            return try await startTask.task.value
        }
        // No start in flight, so a kind here means a session already connected.
        guard sessionKind == nil else { return }
        let mode = mode
        let client = client
        let config = conversationConfig
        dispatchedToolCallIds.removeAll()
        let task = Task {
            try await mode.start(kind, client: client, config: config)
        }
        sessionKind = kind
        endedConversation = nil
        sessionGeneration += 1
        startTask = (kind, task)
        let generation = sessionGeneration
        // Only our own start is cleared: an end, or a later start, may have
        // replaced it while we were connecting.
        defer { if sessionGeneration == generation { startTask = nil } }
        do {
            try await task.value
            warnIfMicrophoneUnavailable()
        } catch {
            // Minting can fail before the client ever leaves idle, and then no
            // state arrives to retire the session this would have been.
            if sessionGeneration == generation { sessionKind = nil }
            if task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    func endConversation() {
        Task { await endConversationAndWait() }
    }

    /// Ending has to outrank a start that is still resolving credentials, or the
    /// connection lands afterwards and leaves the microphone live.
    func endConversationAndWait() async {
        let task = startTask?.task
        startTask = nil
        sessionKind = nil
        task?.cancel()
        await client.endConversation()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        input = ""
        isSending = true
        if banner?.offersSettings != true { dismissBanner() }
        Task {
            do {
                try await send(text)
            } catch is CancellationError {
                if input.isEmpty { input = text }
            } catch {
                // Hand the text back so the user can retry rather than losing it.
                if input.isEmpty { input = text }
                show(ChatWidgetBanner(strings.messageSendFailed))
            }
            isSending = false
        }
    }

    func send(_ text: String) async throws {
        try await startConversationAndWait(mode.typedSessionKind)
        try await client.sendMessage(text)
    }

    func toggleMicMute() {
        Task { try? await client.setMicMuted(!isMicMuted) }
    }

    // MARK: - Banner

    private func show(_ banner: ChatWidgetBanner) {
        self.banner = banner
        bannerDismissal?.cancel()
        bannerDismissal = nil
        // A banner offering Settings needs to stay until it is acted on.
        guard !banner.offersSettings else { return }
        bannerDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
            self?.bannerDismissal = nil
        }
    }

    func dismissBanner() {
        bannerDismissal?.cancel()
        bannerDismissal = nil
        banner = nil
    }

    func openSettings() {
        dismissBanner()
        MicrophonePermission.openSettings()
    }

    // MARK: - Client tools

    private func dispatchNewToolCalls(_ calls: [ClientToolCallEvent]) {
        let ids = Set(calls.map(\.toolCallId))
        let added = ids.subtracting(dispatchedToolCallIds)
        dispatchedToolCallIds.formUnion(added)
        for call in calls where added.contains(call.toolCallId) {
            dispatch(call)
        }
    }

    private func dispatch(_ call: ClientToolCallEvent) {
        let generation = sessionGeneration
        let handler = onClientToolCall
        Task { @MainActor [weak self] in
            let result = if let handler {
                await handler(call)
            } else {
                ClientToolResultEvent(
                    toolCallId: call.toolCallId,
                    result: "No client tool handler is configured in the app.",
                    isError: true
                )
            }
            // The host handler can outlive the conversation that asked for it.
            guard let self, generation == sessionGeneration else { return }
            if call.expectsResponse {
                try? await client.sendToolResult(result)
            } else {
                client.markToolCallCompleted(call.toolCallId)
            }
        }
    }
}
#endif
