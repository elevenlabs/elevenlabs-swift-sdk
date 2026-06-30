#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Combine
import os
import ElevenLabs

@available(iOS 16, macCatalyst 16, *)
@MainActor
final class ChatWidgetViewModel: ObservableObject {
    struct EndedConversation: Equatable {
        let id: String?
        let endedByUser: Bool
        var rating: Int?
    }
    
    struct DraftAttachment: Equatable {
        let fileId: String
        let fileName: String
        let fileExtension: String
        let sizeBytes: Int
        let previewData: Data?
    }
    
    // MARK: - Published state: presentation & lifecycle

    @Published var isOpen: Bool = false
    @Published var mode: ChatMode
    @Published var conversationState: ConversationState = .idle
    @Published var endedConversation: EndedConversation?

    // MARK: - Published state: transcript

    /// Read-only projection of the SDK's `conversation.messages` (plus a few
    /// widget-only synthetic bubbles). Rebuilt by `rebuildMessages(from:)`;
    /// never mutated directly. See `observeConversationMessages()`.
    @Published private(set) var messages: [ChatMessage] = []
    /// Bumped to request the transcript scroll to its bottom anchor.
    @Published private(set) var scrollVersion: Int = 0

    // MARK: - Published state: composer

    @Published var input: String = ""
    /// Bumped whenever `input` is cleared on send. Works around an Apple bug
    /// (FB13727682) where a multi-line `TextField(axis:)` clears its bound value
    /// but fails to *re-render* as empty if an autocorrect/inline-prediction
    /// suggestion was active. The composer observes this and briefly toggles
    /// autocorrection to force a redraw (re-assigning "" alone won't redraw).
    @Published var composerResetToken: Int = 0
    @Published var draftAttachment: DraftAttachment?
    @Published var isUploadingAttachment: Bool = false

    // MARK: - Published state: voice & audio

    @Published var isAgentSpeaking: Bool = false
    @Published var isMicMuted: Bool = true

    /// Per-channel SDK level monitors, exposed for the level-visualizing views
    /// (orb, mic button) to observe **directly**. Audio-rate updates then
    /// re-render only those small subtrees, never this view model — which the
    /// whole widget observes.
    var outputLevels: AudioLevelMonitor { client.outputLevels }
    var inputLevels: AudioLevelMonitor { client.inputLevels }

    // MARK: - Published state: error banner

    /// Transient, dismissible banner for major failures (e.g. a conversation
    /// that couldn't be started). Auto-clears after a few seconds.
    @Published var errorBannerMessage: String?
    /// Whether the current error banner should offer an "Open Settings" action
    /// (e.g. microphone permission was denied and iOS won't re-prompt).
    @Published var errorBannerShowsOpenSettings: Bool = false

    // MARK: - Dependencies

    let widgetConfig: ChatWidgetConfig
    private var strings: ChatWidgetStrings { widgetConfig.strings }
    private let authProvider: () async throws -> ConversationAuth
    // The durable, observable SDK facade. The widget binds to its `@Published`
    // state directly (one set of subscriptions, wired once in `init`) and calls
    // its methods; there is no per-session object to track. Internal (not
    // `private`) so the controller-binding extension in
    // `Internal/ChatWidgetViewModel+Controller.swift` can reach it.
    let client: ConversationClient
    private let baseConversationConfig: ConversationConfig
    private let onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?
    private let onConversationStarted: (@MainActor () -> Void)?

    // MARK: - Internal state

    var isSending: Bool = false
    private var cancellables = Set<AnyCancellable>()
    // De-dup state for the SDK publisher subscriptions (see `observeLifecycle`
    // / `observeToolCalls`), which turn level-triggered `@Published` snapshots
    // into one-shot signals.
    private var emittedConversationStartedFor: String?
    private var lastWasActive = false
    private var lastPendingToolCallIds: Set<String> = []
    private var lastMcpToolCallIds: Set<String> = []
    /// UI-only enrichment layered onto the SDK's canonical messages, keyed by
    /// stable identity so it survives projection rebuilds:
    /// - attachment previews, keyed by the SDK `Message.id` of the user message
    /// - in-conversation feedback selection, keyed by the agent `eventId`
    private var attachmentsByMessageId: [String: ChatMessage.Attachment] = [:]
    private var feedbackByEventId: [Int: FeedbackEvent.Score] = [:]
    /// Widget-only bubbles with no counterpart in `conversation.messages` (MCP
    /// approval prompts, local error notices). Merged into the projection by
    /// timestamp. See `mergeSynthetic(into:)`.
    private var syntheticMessages: [ChatMessage] = []
    private var conversationId: String?
    private var feedbackHandledConversationIds: Set<String> = []
    private var supportsTextInput: Bool = false
    private var lastUserActivitySentAt: Date?
    private var errorBannerDismissTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.elevenlabs.widget", category: "chat-widget")
    
    init(
        authProvider: @escaping () async throws -> ConversationAuth,
        widgetConfig: ChatWidgetConfig,
        client: ConversationClient,
        conversationConfig: ConversationConfig,
        onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)? = nil,
        onConversationStarted: (@MainActor () -> Void)? = nil
    ) {
        
        self.authProvider = authProvider
        self.widgetConfig = widgetConfig
        self.client = client
        self.baseConversationConfig = conversationConfig
        self.onClientToolCall = onClientToolCall
        self.onConversationStarted = onConversationStarted
        
        self.mode = widgetConfig.conversationMode == .textOnly ? .text : .voice

        // The client is durable, so every SDK subscription is wired exactly once
        // here — no per-session rebinding. `bindMode` re-projects the transcript
        // when the text/voice mode flips.
        bindMode()
        observeConversationMessages()
        observeAgentSpeaking()
        observeLifecycle()
        observeToolCalls()

        // `client.state` is the single source of truth for the lifecycle; mirror
        // it one-way into our published `conversationState`.
        client.$state
            .sink { [weak self] state in self?.conversationState = state }
            .store(in: &cancellables)
    }

    /// A bubble's `kind` (text vs. voice transcript) depends on the current
    /// mode, so re-project the (session-independent) message list when mode flips.
    private func bindMode() {
        $mode
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildMessages() }
            .store(in: &cancellables)
    }

    /// Projects the SDK's canonical `client.messages` into the widget's
    /// `messages` whenever it changes, layering on widget-only enrichment
    /// (attachment previews, feedback selection) from sidecars.
    ///
    /// The SDK is the single source of truth: it already reconciles streaming
    /// agent text, corrections, eventId upserts, and user/agent ordering. The
    /// widget keeps no parallel store — it just maps `Message` → `ChatMessage`.
    private func observeConversationMessages() {
        client.$messages
            .sink { [weak self] messages in
                // `@Published` delivers the new value during `willSet`, so use
                // the value handed in rather than re-reading the property.
                self?.rebuildMessages(from: messages)
            }
            .store(in: &cancellables)
    }

    /// Mirrors the SDK's agent-speaking flag into the orb state. The SDK owns the
    /// debounce (fast attack / slow release), so the widget mirrors it directly
    /// with no smoothing of its own.
    private func observeAgentSpeaking() {
        client.$isAgentSpeaking
            .sink { [weak self] speaking in
                guard let self, self.mode == .voice else { return }
                self.isAgentSpeaking = speaking
            }
            .store(in: &cancellables)
    }

    /// Derives one-shot lifecycle signals from the SDK's level-triggered state.
    /// `$conversationMetadata` yields the started signal on first conversation
    /// id; `$state` yields the ended signal on a real active→ended transition
    /// (gated by `lastWasActive` so a fresh `.ended` snapshot doesn't fire). The
    /// client is durable, so the de-dup state auto-resets when a new session
    /// publishes its fresh (`nil` / empty) values.
    private func observeLifecycle() {
        client.$conversationMetadata
            .compactMap { $0?.conversationId }
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                guard self.emittedConversationStartedFor != id else { return }
                self.emittedConversationStartedFor = id
                self.handleConversationStarted(id)
            }
            .store(in: &cancellables)

        client.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                let isActive = !state.isInactive
                defer { self.lastWasActive = isActive }
                if case .ended = state, self.lastWasActive {
                    self.emittedConversationStartedFor = nil
                    self.handleConversationEnded()
                }
            }
            .store(in: &cancellables)
    }

    /// Emits one signal per newly-appended client tool call / newly-pending MCP
    /// approval, diffing each publisher snapshot against the last seen ids.
    private func observeToolCalls() {
        client.$pendingToolCalls
            .sink { [weak self] calls in
                guard let self else { return }
                let newIds = Set(calls.map { $0.toolCallId })
                let added = newIds.subtracting(self.lastPendingToolCallIds)
                self.lastPendingToolCallIds = newIds
                for call in calls where added.contains(call.toolCallId) {
                    self.handleClientToolCall(call)
                }
            }
            .store(in: &cancellables)

        client.$mcpToolCalls
            .sink { [weak self] calls in
                guard let self else { return }
                let awaiting = calls.filter { $0.state == .awaitingApproval }
                let newIds = Set(awaiting.map { $0.toolCallId })
                let added = newIds.subtracting(self.lastMcpToolCallIds)
                self.lastMcpToolCallIds = newIds
                for call in awaiting where added.contains(call.toolCallId) {
                    self.handleMCPApprovalRequest(Self.toApprovalRequest(call))
                }
            }
            .store(in: &cancellables)
    }

    private static func toApprovalRequest(_ call: MCPToolCallEvent) -> MCPToolApprovalRequest {
        let parameters: [String: ConversationConfigValue] = {
            guard let raw = try? call.getParameters() else { return [:] }
            return raw.mapValues { ConversationConfigValue.fromJSONValue($0) }
        }()
        return MCPToolApprovalRequest(
            toolCallId: call.toolCallId,
            toolName: call.toolName,
            toolDescription: call.toolDescription,
            parameters: parameters,
            approvalTimeoutSecs: call.approvalTimeoutSecs
        )
    }

    private func rebuildMessages() {
        rebuildMessages(from: client.messages)
    }

    private func rebuildMessages(from sdkMessages: [Message]) {
        let visible = sdkMessages.filter { message in
            guard message.isPartial else { return true }
            // Tentative (in-progress) user transcripts are gated on the host's
            // `showTentativeUserTranscript` preference.
            if message.role == .user, !widgetConfig.showTentativeUserTranscript { return false }
            // Drop in-progress bubbles that are still blank so an empty ghost
            // bubble never renders (e.g. a tentative transcript before any words).
            return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let projected = visible.map(projectedMessage(from:))
        let merged = mergeSynthetic(into: projected)
        guard merged != messages else { return }
        messages = merged
        requestScrollToBottom()
    }

    private func projectedMessage(from message: Message) -> ChatMessage {
        let role: ChatMessage.Role = message.role == .user ? .user : .agent
        return ChatMessage(
            id: message.id,
            role: role,
            kind: messageKind(for: role),
            content: message.content,
            eventId: message.eventId,
            feedbackScore: message.eventId.flatMap { feedbackByEventId[$0] },
            attachment: attachmentsByMessageId[message.id],
            isPartial: message.isPartial,
            timestamp: message.timestamp
        )
    }

    /// Merges widget-only synthetic bubbles (MCP approval prompts, local error
    /// notices) into the SDK-backed projection by timestamp, while keeping the
    /// SDK's own relative ordering intact.
    private func mergeSynthetic(into projected: [ChatMessage]) -> [ChatMessage] {
        guard !syntheticMessages.isEmpty else { return projected }
        var result = projected
        for synthetic in syntheticMessages {
            if let idx = result.firstIndex(where: { $0.timestamp > synthetic.timestamp }) {
                result.insert(synthetic, at: idx)
            } else {
                result.append(synthetic)
            }
        }
        return result
    }

    private func messageKind(for role: ChatMessage.Role) -> ChatMessage.Kind {
        mode == .voice ? .voiceTranscript : .text
    }

    private func appendSyntheticMessage(_ message: ChatMessage) {
        syntheticMessages.append(message)
        rebuildMessages()
    }

    /// Records the in-conversation feedback selection for an agent message and
    /// re-projects so the bubble reflects it.
    func applyFeedback(_ score: FeedbackEvent.Score, eventId: Int) {
        feedbackByEventId[eventId] = score
        rebuildMessages()
        requestScrollToBottom()
    }

    /// Marks an MCP approval prompt as approved/rejected and re-projects.
    func applyMCPApprovalStatus(_ status: ChatMessage.MCPApprovalStatus, toolCallId: String) {
        guard let idx = syntheticMessages.firstIndex(where: {
            $0.mcpApprovalRequest?.toolCallId == toolCallId
        }) else { return }
        syntheticMessages[idx].mcpApprovalStatus = status
        rebuildMessages()
        requestScrollToBottom()
    }

    var canSend: Bool {
        !isSending &&
        (
            !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            draftAttachment != nil
        ) &&
        canShowTextInput
    }
    
    var canUploadFile: Bool {
        widgetConfig.enableFileUpload &&
        conversationState == .connected &&
        conversationId != nil &&
        canShowTextInput &&
        !isUploadingAttachment
    }
    
    var canShowTextInput: Bool {
        widgetConfig.conversationMode.supportsTextInput
    }
    
    var canStartVoiceConversation: Bool {
        widgetConfig.conversationMode.supportsVoice && conversationState.isInactive
    }
    
    var canEndConversation: Bool {
        !conversationState.isInactive
    }
    
    var canToggleMicMute: Bool {
        widgetConfig.enableMicMuteControl && mode == .voice && conversationState == .connected
    }
    
    var shouldShowMessages: Bool {
        mode == .text || widgetConfig.showVoiceMessages
    }
    
    var hasActiveConversation: Bool {
        !conversationState.isInactive
    }
    
    var shouldShowCenterOrb: Bool {
        !shouldShowMessages || (
            widgetConfig.conversationMode.supportsVoice &&
            conversationState != .connected &&
            messages.isEmpty &&
            endedConversation == nil
        )
    }
    
    var orbState: ChatOrbState {
        switch conversationState {
        case .idle:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return isAgentSpeaking ? .speaking : .listening
        case .ended:
            // SDK uses `.ended(reason:)` instead of `.disconnected`; map to the
            // widget's disconnected orb state.
            return .disconnected
        case .startupFailed:
            return .unknown
        }
    }
    
    func toggleOpen() { isOpen.toggle() }
    func close()      { isOpen = false }

    /// Surfaces a transient failure banner that auto-dismisses after 5s. A new
    /// message resets the timer; `dismissErrorBanner()` clears it early. Pass
    /// `showsOpenSettings` for failures the user can only resolve in Settings
    /// (e.g. a denied microphone permission).
    func showErrorBanner(_ message: String, showsOpenSettings: Bool = false) {
        errorBannerMessage = message
        errorBannerShowsOpenSettings = showsOpenSettings
        errorBannerDismissTask?.cancel()
        errorBannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.errorBannerMessage = nil
            self?.errorBannerShowsOpenSettings = false
            self?.errorBannerDismissTask = nil
        }
    }

    /// Picks the right start-failure banner: a denied microphone permission is
    /// only fixable in Settings (iOS won't re-prompt), so it gets an actionable
    /// banner; everything else falls back to a generic retry message.
    private func presentStartFailureBanner(for error: Error?) {
        if let conversationError = error as? ConversationError,
           conversationError == .microphonePermissionDenied {
            showErrorBanner(
                conversationError.errorDescription ?? strings.microphoneAccessOff,
                showsOpenSettings: true
            )
        } else {
            showErrorBanner(strings.startConversationFailed)
        }
    }

    func dismissErrorBanner() {
        errorBannerDismissTask?.cancel()
        errorBannerDismissTask = nil
        errorBannerMessage = nil
        errorBannerShowsOpenSettings = false
    }

    /// Deep-links to this app's page in the system Settings so the user can
    /// re-enable a permission iOS will no longer prompt for (e.g. microphone).
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        dismissErrorBanner()
    }
    
    func requestScrollToBottom() {
        scrollVersion += 1
    }
    
    func endConversation() {
        finalizeEndedConversation(endedByUser: true)
        Task {
            await client.endConversation()
        }
    }

    func finalizeEndedConversation(endedByUser: Bool) {
        guard endedConversation == nil else { return }

        let endedConversationId = conversationId ?? client.conversationMetadata?.conversationId

        // Capture the ids before we clear them below so the best-effort remote
        // delete still targets the right file; the local draft is dropped
        // synchronously so a pending attachment never lingers after the call.
        if let endedConversationId, let draft = draftAttachment {
            Task { [weak self] in
                try? await self?.client.deleteConversationFile(conversationId: endedConversationId, fileId: draft.fileId)
            }
        }
        draftAttachment = nil
        isUploadingAttachment = false
        endedConversation = EndedConversation(id: endedConversationId, endedByUser: endedByUser, rating: nil)
        requestScrollToBottom()
        isAgentSpeaking = false
        isMicMuted = true
        input = ""
        conversationId = nil
    }
    
    /// Whether the post-conversation feedback sheet should be presented for the
    /// given conversation. Returns false once it has already been shown, so it
    /// won't re-appear if the widget is collapsed and reopened.
    func shouldPromptFeedback(for conversationId: String) -> Bool {
        !feedbackHandledConversationIds.contains(conversationId)
    }
    
    func markFeedbackHandled(for conversationId: String) {
        feedbackHandledConversationIds.insert(conversationId)
    }
    
    /// Submits the post-conversation feedback (star rating and/or free-text comment)
    /// in a single call. Unlike `rate(_:)`, this does not fire on every star tap –
    /// it is invoked once when the user taps "Submit" in the feedback sheet.
    func submitFeedback(rating: Int?, comment: String?) {
        guard var endedConversation else { return }
        endedConversation.rating = rating
        self.endedConversation = endedConversation
        
        guard widgetConfig.collectFeedbackAfterCall, let conversationId = endedConversation.id else { return }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalComment = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let finalRating = rating ?? 0
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.submitPostCallFeedback(
                    conversationId: conversationId,
                    rating: finalRating,
                    comment: finalComment
                )
            } catch {
                self.logger.error("submitFeedback failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func startVoiceConversation() {
        guard canStartVoiceConversation else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startVoiceConversationCore()
            } catch {
                self.logger.error("startVoiceConversation failed: \(error.localizedDescription, privacy: .public)")
                self.presentStartFailureBanner(for: error)
            }
        }
    }

    /// Start-a-voice-session core that actually awaits the connection and
    /// rethrows on failure. The fire-and-forget UI wrapper above turns the error
    /// into a banner; the host controller path (`startConversationFromHost`) lets
    /// it propagate so `try await controller.startConversation()` is honest.
    func startVoiceConversationCore() async throws {
        await prepareForNewConversation()
        dismissErrorBanner()
        mode = .voice
        do {
            let auth = try await authProvider()
            try await client.start(auth: auth, config: makeConversationConfig(textOnly: false))
        } catch {
            isMicMuted = true
            throw error
        }
        guard client.state == .connected else {
            isMicMuted = true
            throw ConversationError.connectionFailed("Conversation did not reach the connected state.")
        }
        isMicMuted = client.isMicMuted
    }
    
    func toggleMicMute() {
        guard canToggleMicMute else { return }
        let targetMuted = !isMicMuted
        isMicMuted = targetMuted
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.setMicMuted(targetMuted)
                self.isMicMuted = self.client.isMicMuted
            } catch {
                self.isMicMuted = !targetMuted
                self.logger.error("toggleMicMute failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func handleTypingActivity() {
        guard widgetConfig.sendUserActivityOnTyping,
              conversationState == .connected
        else {
            return
        }
        
        let now = Date()
        if let lastUserActivitySentAt,
           now.timeIntervalSince(lastUserActivitySentAt) < widgetConfig.userActivityThrottleInterval {
            return
        }
        lastUserActivitySentAt = now
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.interruptAgent()
            } catch {
                self.logger.error("interruptAgent failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func sendText() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = draftAttachment
        guard !trimmed.isEmpty || attachment != nil else { return }
        
        if client.state != .connected {
            resetForNewConversation()
        }
        
        // No optimistic bubble: the SDK appends the user message to
        // `client.messages` when the send is published, which the
        // projection renders. Any attachment preview is correlated to that SDK
        // message id in `performSend(text:attachment:)`.
        input = ""
        composerResetToken &+= 1
        isSending = true
        endedConversation = nil
        
        Task { [weak self] in
            await self?.performSend(text: trimmed, attachment: attachment)
        }
    }
    
    func uploadFile(url: URL) {
        Task { [weak self] in
            await self?.performUploadFile(url: url)
        }
    }
    
    func removeDraftAttachment() {
        Task { [weak self] in
            await self?.performRemoveDraftAttachment()
        }
    }
    
    func sendInConversationFeedback(for message: ChatMessage, score: FeedbackEvent.Score) {
        guard let eventId = message.eventId else { return }
        applyFeedback(score, eventId: eventId)
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendFeedback(score, eventId: eventId)
            } catch {
                self.logWidgetError(prefix: "in-conversation feedback", error: error)
            }
        }
    }
    
    func respondToMCPApproval(for message: ChatMessage, approved: Bool) {
        guard let request = message.mcpApprovalRequest,
              message.mcpApprovalStatus == nil
        else {
            return
        }
        
        applyMCPApprovalStatus(approved ? .approved : .rejected, toolCallId: request.toolCallId)
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendMCPToolApproval(
                    toolCallId: request.toolCallId,
                    isApproved: approved
                )
            } catch {
                self.logger.error("sendMCPToolApproval failed: \(error.localizedDescription, privacy: .public)")
                self.appendSyntheticMessage(
                    ChatMessage(
                        role: .agent,
                        kind: .error,
                        content: strings.mcpApprovalResponseFailed
                    )
                )
            }
        }
    }
    
    private func performSend(text: String, attachment: DraftAttachment?) async {
        defer { isSending = false }
        
        if client.state != .connected {
            let textOnly = shouldStartTextConversationFromText()
            mode = textOnly ? .text : .voice
            var startError: Error?
            do {
                let auth = try await self.authProvider()
                try await client.start(auth: auth, config: makeConversationConfig(textOnly: textOnly))
            } catch {
                startError = error
                logger.error("failed to start conversation: \(error.localizedDescription, privacy: .public)")
            }
            if client.state == .connected {
                isMicMuted = client.isMicMuted
            } else {
                isMicMuted = true
                presentStartFailureBanner(for: startError)
                return
            }
        }

        guard client.state == .connected else { return }
        do {
            if let attachment {
                let normalizedText = text.isEmpty ? nil : text
                try await client.sendMultimodalMessage(text: normalizedText, fileId: attachment.fileId)
                correlateAttachment(attachment)
                draftAttachment = nil
            } else {
                try await client.sendMessage(text)
            }
        } catch {
            logWidgetError(prefix: "send", error: error)
            appendSyntheticMessage(
                ChatMessage(role: .agent, kind: .error, content: strings.sendMessageFailed)
            )
        }
    }

    /// Host-initiated text send (via `ChatWidgetController.sendMessage`). Unlike
    /// the UI `sendText()` path it does **not** touch the live composer `input`
    /// (which would clobber whatever the user is typing) and it awaits + rethrows
    /// so the caller sees real completion/errors instead of fire-and-forget.
    /// Text-only by design — the host command carries no attachment.
    func sendMessageFromHostCore(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if client.state != .connected {
            let textOnly = shouldStartTextConversationFromText()
            mode = textOnly ? .text : .voice
            resetForNewConversation()
            do {
                let auth = try await authProvider()
                try await client.start(auth: auth, config: makeConversationConfig(textOnly: textOnly))
            } catch {
                isMicMuted = true
                throw error
            }
            guard client.state == .connected else {
                isMicMuted = true
                throw ConversationError.connectionFailed("Conversation did not reach the connected state.")
            }
            isMicMuted = client.isMicMuted
        }

        endedConversation = nil
        try await client.sendMessage(trimmed)
    }

    /// Attaches the local preview for an uploaded file to the user `Message`
    /// the SDK just appended. The SDK appends synchronously on the main actor,
    /// so the most recent `.user` entry is the message we just sent.
    private func correlateAttachment(_ attachment: DraftAttachment) {
        guard let messageId = client.messages.last(where: { $0.role == .user })?.id else { return }
        attachmentsByMessageId[messageId] = ChatMessage.Attachment(
            fileName: attachment.fileName,
            fileExtension: attachment.fileExtension,
            previewData: attachment.previewData
        )
        rebuildMessages()
    }
    
    private func performUploadFile(url: URL) async {
        guard canUploadFile else { return }
        guard let conversationId else { return }
        
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileName = url.lastPathComponent
        let fileExtension = url.pathExtension.lowercased()
        guard supportedFileExtensions.contains(fileExtension) else {
            showErrorBanner(strings.unsupportedFileType)
            return
        }
        
        guard let fileData = try? Data(contentsOf: url) else {
            showErrorBanner(strings.fileReadFailed)
            return
        }
        
        let fileSize = fileData.count
        if !isFileSizeValid(fileExtension: fileExtension, sizeBytes: fileSize) {
            let limit = fileExtension == "pdf" ? "20MB" : "10MB"
            showErrorBanner(String(format: strings.fileTooLargeFormat, limit))
            return
        }
        
        if draftAttachment != nil {
            await performRemoveDraftAttachment()
        }
        
        isUploadingAttachment = true
        defer { isUploadingAttachment = false }
        
        do {
            let fileId = try await client.uploadConversationFile(
                conversationId: conversationId,
                fileName: fileName,
                mimeType: mimeType(for: fileExtension),
                fileData: fileData
            )
            draftAttachment = DraftAttachment(
                fileId: fileId,
                fileName: fileName,
                fileExtension: fileExtension,
                sizeBytes: fileSize,
                previewData: fileExtension == "pdf" ? nil : fileData
            )
        } catch {
            logWidgetError(prefix: "upload", error: error)
            showErrorBanner(uploadErrorMessage(from: error))
        }
    }
    
    private func performRemoveDraftAttachment() async {
        guard let conversationId, let draftAttachment else { return }
        
        do {
            try await client.deleteConversationFile(conversationId: conversationId, fileId: draftAttachment.fileId)
        } catch {
            logWidgetError(prefix: "delete", error: error)
        }
        self.draftAttachment = nil
    }
    
    private func handleConversationStarted(_ id: String) {
        conversationId = id
        isMicMuted = client.isMicMuted
        supportsTextInput = widgetConfig.conversationMode.supportsTextInput
        onConversationStarted?()
    }

    private func handleConversationEnded() {
        finalizeEndedConversation(endedByUser: false)
    }

    private func handleMCPApprovalRequest(_ request: MCPToolApprovalRequest) {
        appendSyntheticMessage(
            ChatMessage(
                role: .agent,
                kind: .mcpApprovalRequest,
                content: mcpApprovalMessage(for: request),
                mcpApprovalRequest: request
            )
        )
    }
    
    private func mcpApprovalMessage(for request: MCPToolApprovalRequest) -> String {
        let params = request.parameters
            .map { "\($0.key)=\($0.value.displayValue)" }
            .sorted()
            .joined(separator: ", ")
        let timeout = request.approvalTimeoutSecs.map { String(format: strings.mcpApprovalExpiresFormat, "\($0)") }
        
        return [
            String(format: strings.mcpToolRequestFormat, request.toolName),
            request.toolDescription,
            params.isEmpty ? nil : String(format: strings.mcpParametersFormat, params),
            timeout,
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }
    
    private func handleClientToolCall(_ call: ClientToolCallEvent) {
        guard let onClientToolCall else {
            guard call.expectsResponse else {
                client.markToolCallCompleted(call.toolCallId)
                return
            }
            Task { [weak self] in
                try? await self?.client.sendToolResult(
                    for: call.toolCallId,
                    result: "No client tool handler is configured in the app.",
                    isError: true,
                    errorType: .externalClient
                )
            }
            return
        }
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await onClientToolCall(call)
            do {
                if call.expectsResponse {
                    try await self.client.sendToolResult(
                        for: call.toolCallId,
                        result: result.result,
                        isError: result.isError,
                        errorType: result.errorType
                    )
                } else {
                    self.client.markToolCallCompleted(call.toolCallId)
                }
            } catch {
                self.logger.error("sendToolResult failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func shouldStartTextConversationFromText() -> Bool {
        widgetConfig.conversationMode == .textOnly ||
        widgetConfig.conversationMode == .voiceAndTextWithTextOnly
    }
    
    private func prepareForNewConversation() async {
        await performRemoveDraftAttachment()
        resetForNewConversation()
    }
    
    private func resetForNewConversation() {
        clearMessageProjection()
        endedConversation = nil
        conversationId = nil
        input = ""
        draftAttachment = nil
        isUploadingAttachment = false
        isAgentSpeaking = false
        isMicMuted = true
        supportsTextInput = false
        lastUserActivitySentAt = nil
    }

    /// Drops the displayed transcript and all UI-only enrichment so a fresh
    /// conversation starts clean. The SDK clears `conversation.messages` itself
    /// on start; this clears the widget's projection + sidecars synchronously.
    private func clearMessageProjection() {
        attachmentsByMessageId.removeAll()
        feedbackByEventId.removeAll()
        syntheticMessages.removeAll()
        messages = []
    }
    
    /// Resolves the per-start configuration: the host-supplied base config with
    /// the text-only flag set for this session. The `ConversationClient` lifecycle
    /// passes this to each new `Conversation`, so the same widget can start either
    /// a voice or a text session depending on how it was triggered.
    private func makeConversationConfig(textOnly: Bool) -> ConversationConfig {
        var config = baseConversationConfig
        config.textOnly = textOnly
        return config
    }
    
    private func isFileSizeValid(fileExtension: String, sizeBytes: Int) -> Bool {
        let imageLimit = 10 * 1024 * 1024
        let pdfLimit = 20 * 1024 * 1024
        if fileExtension == "pdf" {
            return sizeBytes <= pdfLimit
        }
        return sizeBytes <= imageLimit
    }
    
    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }
    
    private var supportedFileExtensions: Set<String> {
        ["png", "jpg", "jpeg", "gif", "webp", "pdf"]
    }
    
    private func logWidgetError(prefix: String, error: Error) {
        let detail = (error as? ConversationError)?.errorDescription ?? error.localizedDescription
        logger.error("\(prefix, privacy: .public) failed: \(detail, privacy: .public)")
    }
    
    private func uploadErrorMessage(from error: Error) -> String {
        if let apiError = error as? ConversationError {
            return apiError.errorDescription ?? strings.genericError
        }
        return strings.fileUploadFailed
    }
    
}

private extension ConversationConfigValue {
    var displayValue: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
        case .boolean(let value):
            return String(value)
        case .object:
            return "{...}"
        case .array:
            return "[...]"
        case .null:
            return "null"
        }
    }
}

#endif
