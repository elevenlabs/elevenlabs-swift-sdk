#if canImport(UIKit)
import ElevenLabs
import Foundation

/// The contract a `ChatWidgetController` forwards commands through.
///
/// `ChatWidgetViewModel` conforms to this. The controller holds it via a weak
/// reference so the controller can outlive the widget (commands become no-ops
/// after the widget tears down) without keeping the VM alive.
///
/// Internal to the widget module — consumers don't see this protocol.
@available(iOS 16, macCatalyst 16, *)
@MainActor
internal protocol ChatWidgetControllerBinding: AnyObject {
    // UI state
    func open()
    func close()
    func toggleOpen()

    // Conversation lifecycle
    func startConversationFromHost() async throws
    func endConversationFromHost() async

    // Send + interact
    func sendMessageFromHost(_ text: String) async throws
    func sendContextualUpdateFromHost(_ text: String) async throws
    func setMicMutedFromHost(_ muted: Bool) async throws
    func sendFeedbackFromHost(_ score: FeedbackEvent.Score, eventId: Int) async throws
    func sendMCPApprovalFromHost(toolCallId: String, isApproved: Bool) async throws

    // Snapshot accessors
    func currentMessages() -> [Message]
}
#endif
