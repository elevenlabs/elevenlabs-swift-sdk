#if canImport(UIKit)
import ElevenLabs
import Foundation

/// Host-owned handle for observing widget state and driving it from outside.
///
/// Optional — pass one to ``ChatWidget`` to read state through the `@Published`
/// mirrors and to issue commands.
///
/// The controller may outlive the widget: once the widget view is gone, commands
/// become no-ops and the mirrors stop updating. Mirrors are read-only from the
/// host so state only ever changes through a command.
@available(iOS 16, macCatalyst 16, *)
@MainActor
public final class ChatWidgetController: ObservableObject {
    @Published public internal(set) var state: ConversationState = .idle
    @Published public internal(set) var isMicMuted = false
    @Published public internal(set) var isOpen = false
    /// Server-assigned conversation id; `nil` until the agent confirms the session.
    @Published public internal(set) var conversationId: String?
    @Published public internal(set) var messageCount = 0

    public init() {}

    public func open() {
        binding?.open()
    }

    public func close() {
        binding?.close()
    }

    public func toggleOpen() {
        binding?.toggleOpen()
    }

    /// Start a conversation, awaiting the connection. No-op if one is live.
    public func startConversation() async throws {
        try await binding?.startConversationAndWait()
    }

    /// End the conversation, awaiting teardown. Cancels a start that hasn't
    /// connected yet.
    public func endConversation() async {
        await binding?.endConversationAndWait()
    }

    /// Send a message as the user, connecting first if needed.
    public func sendMessage(_ text: String) async throws {
        try await binding?.send(text)
    }

    public func setMicMuted(_ muted: Bool) async throws {
        try await binding?.client.setMicMuted(muted)
    }

    /// Snapshot of the conversation's messages. Not reactive — read it when you
    /// need it (e.g. on end of call).
    public func messages() -> [Message] {
        binding?.client.messages ?? []
    }

    /// Set by the widget on attach. Weak so the controller can outlive the widget.
    weak var binding: ChatWidgetViewModel?

    /// Called when the widget goes away, since the mirrors would otherwise keep
    /// reporting the last state of a conversation that no longer exists.
    func reset() {
        state = .idle
        isMicMuted = false
        isOpen = false
        conversationId = nil
        messageCount = 0
    }
}

@available(iOS 16, macCatalyst 16, *)
extension ChatWidgetViewModel {
    func attach(to controller: ChatWidgetController) {
        guard controller.binding !== self else { return }
        controller.binding = self
        self.controller = controller

        $conversationState.assign(to: &controller.$state)
        $isMicMuted.assign(to: &controller.$isMicMuted)
        $isOpen.assign(to: &controller.$isOpen)
        $messages.map(\.count).assign(to: &controller.$messageCount)
        client.$conversationMetadata
            .map { $0?.conversationId }
            .assign(to: &controller.$conversationId)
    }
}
#endif
