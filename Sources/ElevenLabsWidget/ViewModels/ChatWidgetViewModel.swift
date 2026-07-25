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

    let widgetConfig: ChatWidgetConfig
    let client: ConversationClient

    private let authProvider: () async throws -> ConversationCredentials
    private let conversationConfig: ConversationConfig
    private let onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?
    /// Tool calls already dispatched, so a re-published snapshot doesn't run them twice.
    private var dispatchedToolCallIds: Set<String> = []
    /// The in-flight startup, so overlapping callers join it instead of racing.
    private var startTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()

    init(
        authProvider: @escaping () async throws -> ConversationCredentials,
        widgetConfig: ChatWidgetConfig,
        client: ConversationClient,
        conversationConfig: ConversationConfig,
        onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?
    ) {
        self.authProvider = authProvider
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
    }

    /// The host can drop the widget mid-call, and nothing else owns the client,
    /// so the session and the microphone would otherwise stay live.
    deinit {
        let client = client
        Task { @MainActor in await client.endConversation() }
    }

    // MARK: - Derived state

    var hasActiveConversation: Bool {
        conversationState.isConnecting || conversationState.isConnected
    }

    var canSend: Bool {
        !isSending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canToggleMicMute: Bool {
        widgetConfig.enableMicMuteControl && conversationState.isConnected
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
        Task { try? await startConversationAndWait() }
    }

    func startConversationAndWait() async throws {
        // Joining first matters while connecting: returning early there would let
        // a send reach the agent before the session is up.
        if let startTask { return try await startTask.value }
        guard !hasActiveConversation else { return }
        let task = Task {
            _ = try await client.startConversation(auth: authProvider(), config: conversationConfig)
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    func endConversation() {
        Task { await client.endConversation() }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        input = ""
        isSending = true
        Task {
            do {
                try await send(text)
            } catch {
                // Hand the text back so the user can retry rather than losing it.
                if input.isEmpty { input = text }
            }
            isSending = false
        }
    }

    func send(_ text: String) async throws {
        try await startConversationAndWait()
        try await client.sendMessage(text)
    }

    func toggleMicMute() {
        Task { try? await client.setMicMuted(!isMicMuted) }
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
        Task { @MainActor [weak self] in
            let result = await onClientToolCall(call)
            self?.respond(to: call, with: result)
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
