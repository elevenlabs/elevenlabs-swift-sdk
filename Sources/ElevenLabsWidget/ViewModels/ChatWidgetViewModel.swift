#if canImport(UIKit)
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

    /// All three mirror what the host passes to ``ChatWidget``, so changes land
    /// on the live view model instead of needing a new conversation.
    var mode: WidgetConversationMode
    var onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?
    @Published var widgetConfig: ChatWidgetConfig
    let client: ConversationClient

    private let conversationConfig: ConversationConfig
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

        // The client is durable across sessions, so every subscription is wired once.
        client.$state.assign(to: &$conversationState)
        client.$agentState.assign(to: &$agentState)
        client.$isMicMuted.assign(to: &$isMicMuted)
        client.$messages
            .map { $0.map(ChatMessage.init) }
            .assign(to: &$messages)
        client.$pendingToolCalls
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
        case .connected: agentState == .speaking ? .speaking : .listening
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
                warnIfMicrophoneUnavailable()
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
        let config = conversationConfig(for: kind)
        let task = Task {
            _ = try await client.startConversation(
                auth: mode.credentials(for: kind),
                config: config
            )
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
        } catch {
            // Minting can fail before the client ever leaves idle, and then no
            // state arrives to retire the session this would have been.
            if sessionGeneration == generation { sessionKind = nil }
            throw error
        }
    }

    /// Text-only sessions run the conversation without audio.
    private func conversationConfig(for kind: WidgetSessionKind) -> ConversationConfig {
        guard kind == .textOnly else { return conversationConfig }
        var config = conversationConfig
        config.conversationOverrides.textOnly = true
        return config
    }

    func endConversation() {
        Task { await endConversationAndWait() }
    }

    /// Ending has to outrank a start that is still resolving credentials, or the
    /// connection lands afterwards and leaves the microphone live.
    func endConversationAndWait() async {
        let start = startTask
        let generation = sessionGeneration
        startTask = nil
        sessionKind = nil
        start?.task.cancel()
        await client.endConversation()
        guard let start else { return }
        // A start that ignored the cancel still connects, so wait it out and
        // tear it down — unless a newer session has begun in the meantime.
        _ = try? await start.task.value
        if sessionGeneration == generation { await client.endConversation() }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        input = ""
        isSending = true
        dismissBanner()
        Task {
            do {
                try await send(text)
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
        // A banner offering Settings needs to stay until it is acted on.
        guard !banner.offersSettings else { return }
        bannerDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        bannerDismissal?.cancel()
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
        dispatchedToolCallIds = ids
        for call in calls where added.contains(call.toolCallId) {
            dispatch(call)
        }
    }

    private func dispatch(_ call: ClientToolCallEvent) {
        guard let onClientToolCall else {
            respond(to: call, with: .init(
                toolCallId: call.toolCallId,
                result: "No client tool handler is configured in the app.",
                isError: true
            ))
            return
        }
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            let result = await onClientToolCall(call)
            // The host handler can outlive the conversation that asked for it.
            guard let self, generation == sessionGeneration else { return }
            respond(to: call, with: result)
        }
    }

    private func respond(to call: ClientToolCallEvent, with result: ClientToolResultEvent) {
        guard call.expectsResponse else {
            client.markToolCallCompleted(call.toolCallId)
            return
        }
        Task { try? await client.sendToolResult(result) }
    }
}
#endif
