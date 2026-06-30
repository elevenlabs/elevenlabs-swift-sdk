#if canImport(UIKit)
import Combine
import ElevenLabs
import Foundation

/// Host-owned handle for observing widget state and issuing commands.
///
/// Optional — most consumers don't need it. Pass one to `ChatWidget(controller:)`
/// to read state via `@Published` mirrors and to call methods that drive the
/// widget from outside.
///
/// Lifecycle: the controller is safe to outlive the widget. When the widget
/// view is removed from the hierarchy, command methods become no-ops and state
/// mirrors stop updating. Pass the same controller to a re-created widget to
/// resume the connection.
///
/// State mirrors are read-only (`internal(set)`). To change state, call the
/// corresponding command method — that avoids the two-way-binding-loop problem
/// that bare `@Published var` would create.
@available(iOS 16, macCatalyst 16, *)
@MainActor
public final class ChatWidgetController: ObservableObject {
    // MARK: - State mirrors (read-only from host)

    /// Connection state of the underlying conversation.
    @Published public internal(set) var state: ConversationState = .idle

    /// Whether the agent is currently speaking.
    @Published public internal(set) var isAgentSpeaking: Bool = false

    /// Whether the **microphone (input)** is currently muted. This reflects mic
    /// mute only — it is unrelated to muting the agent's audio output.
    @Published public internal(set) var isMicMuted: Bool = true

    /// Whether the widget drawer is currently open.
    @Published public internal(set) var isOpen: Bool = false

    /// Server-assigned id of the current conversation, if any. `nil` before the
    /// agent has confirmed the session.
    @Published public internal(set) var conversationId: String?

    /// Total number of messages in the current conversation. For the full
    /// message stream, use `ConversationCallbacks.onAgentResponse` /
    /// `onUserTranscript`, or observe `Conversation.messages` via the core SDK.
    @Published public internal(set) var messageCount: Int = 0

    // MARK: - Commands

    /// Open the chat drawer.
    public func open() { binding?.open() }

    /// Close the chat drawer.
    public func close() { binding?.close() }

    /// Toggle the chat drawer.
    public func toggleOpen() { binding?.toggleOpen() }

    /// Start a new conversation. No-op if the conversation is already active.
    /// Maps to the widget's voice-start flow; text-only widgets start their
    /// conversation lazily on the first `sendMessage` call.
    public func startConversation() async throws {
        try await binding?.startConversationFromHost()
    }

    /// End the current conversation. No-op if no conversation is active.
    public func endConversation() async {
        await binding?.endConversationFromHost()
    }

    /// Send a message on the user's behalf (e.g. a host-initiated proactive prompt).
    public func sendMessage(_ text: String) async throws {
        try await binding?.sendMessageFromHost(text)
    }

    /// Send a silent contextual update to the agent (no user-visible message).
    public func sendContextualUpdate(_ text: String) async throws {
        try await binding?.sendContextualUpdateFromHost(text)
    }

    /// Mute or unmute the microphone (input).
    public func setMicMuted(_ muted: Bool) async throws {
        try await binding?.setMicMutedFromHost(muted)
    }

    /// Submit feedback for a specific agent event.
    public func sendFeedback(_ score: FeedbackEvent.Score, eventId: Int) async throws {
        try await binding?.sendFeedbackFromHost(score, eventId: eventId)
    }

    /// Approve or reject an MCP tool-call request.
    public func sendMCPApproval(toolCallId: String, isApproved: Bool) async throws {
        try await binding?.sendMCPApprovalFromHost(toolCallId: toolCallId, isApproved: isApproved)
    }

    /// Snapshot of the current conversation's messages. **Not reactive** — call
    /// at the moment you need them (e.g. on end-of-call for export / analytics).
    /// For per-message reactivity, use `ConversationCallbacks.onAgentResponse` /
    /// `onUserTranscript`.
    public func messages() -> [Message] {
        binding?.currentMessages() ?? []
    }

    // MARK: - Internal wiring

    public init() {}

    /// Set by the widget VM on attach. Weak so the controller doesn't keep the
    /// widget VM (and its `Conversation`) alive after the view tears down.
    internal weak var binding: ChatWidgetControllerBinding?
}
#endif
