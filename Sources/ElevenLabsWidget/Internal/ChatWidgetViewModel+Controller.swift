#if canImport(UIKit)
import Combine
import ElevenLabs
import Foundation

// MARK: - Binding conformance + host-callable command adapters
//
// The widget VM already has methods for most of these operations under
// slightly different names / shapes (some take ChatMessage references; others
// route through the input field). The wrappers here translate host-friendly
// signatures (raw eventIds, plain text) into the VM's existing internals.

@available(iOS 16, macCatalyst 16, *)
extension ChatWidgetViewModel: ChatWidgetControllerBinding {
    func open() {
        isOpen = true
    }

    func startConversationFromHost() async throws {
        // No-op for text-only widgets / when already active (mirrors the UI's own
        // `canStartVoiceConversation` guard); text conversations start lazily on
        // the first sendMessage call. Voice sessions genuinely await the
        // connection and rethrow so the host sees the real outcome.
        guard canStartVoiceConversation else { return }
        try await startVoiceConversationCore()
    }

    func endConversationFromHost() async {
        // Update the UI synchronously (up to the first suspension), then await
        // the actual teardown so the caller's `await` reflects real completion.
        finalizeEndedConversation(endedByUser: true)
        await client.endConversation()
    }

    func sendMessageFromHost(_ text: String) async throws {
        // Sends the host's text directly (lazy-connecting if needed) and awaits
        // the send. Deliberately does NOT route through the live composer `input`
        // — doing so would overwrite whatever the user is currently typing.
        try await sendMessageFromHostCore(text)
    }

    func sendContextualUpdateFromHost(_ text: String) async throws {
        try await client.updateContext(text)
    }

    func setMicMutedFromHost(_ muted: Bool) async throws {
        try await client.setMicMuted(muted)
        isMicMuted = client.isMicMuted
    }

    func sendFeedbackFromHost(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        try await client.sendFeedback(score, eventId: eventId)
        // Mirror in the projection so the feedback UI updates.
        applyFeedback(score, eventId: eventId)
    }

    func sendMCPApprovalFromHost(toolCallId: String, isApproved: Bool) async throws {
        try await client.sendMCPToolApproval(toolCallId: toolCallId, isApproved: isApproved)
        applyMCPApprovalStatus(isApproved ? .approved : .rejected, toolCallId: toolCallId)
    }

    // Read-on-demand snapshot of the SDK's canonical message array. Named
    // differently from the VM's own `messages: [ChatMessage]` (widget UI model)
    // to avoid a same-scope name+type clash.
    func currentMessages() -> [Message] {
        client.messages
    }
}

// MARK: - Controller attach
//
// Called once from `ChatWidget.init` when a controller is supplied. Sets up
// the command path (weak reference back to VM) and the state-mirroring
// publishers. `assign(to: &...)` keeps the subscription tied to the
// destination's lifetime — no manual cancellable storage needed.

@available(iOS 16, macCatalyst 16, *)
extension ChatWidgetViewModel {
    func attach(to controller: ChatWidgetController) {
        // 1. Wire commands
        controller.binding = self

        // 2. Mirror state — VM @Published → controller @Published
        $conversationState.assign(to: &controller.$state)
        $isMicMuted.assign(to: &controller.$isMicMuted)
        $isOpen.assign(to: &controller.$isOpen)
        $messages.map(\.count).assign(to: &controller.$messageCount)

        // 3. Mirror SDK state straight from the durable client. The client
        // outlives every session, so these bind once — no per-session rebinding.
        client.$isAgentSpeaking.assign(to: &controller.$isAgentSpeaking)
        client.$conversationMetadata
            .map { $0?.conversationId }
            .assign(to: &controller.$conversationId)
    }
}
#endif
