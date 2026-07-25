#if canImport(UIKit)
import Foundation

/// User-facing copy for ``ChatWidget``. Override individual fields to localize
/// or reword; every field has an English default.
public struct ChatWidgetStrings: Equatable, Sendable {
    public var title: String
    public var mainLabel: String
    public var inputPlaceholder: String
    public var openChatLabel: String
    public var closeChatLabel: String
    public var sendMessageLabel: String
    public var startConversationLabel: String
    public var endConversationLabel: String
    public var muteMicrophoneLabel: String
    public var unmuteMicrophoneLabel: String

    public init(
        title: String = "Chat",
        mainLabel: String = "Powered by ElevenLabs",
        inputPlaceholder: String = "Type a message…",
        openChatLabel: String = "Open chat",
        closeChatLabel: String = "Close chat",
        sendMessageLabel: String = "Send message",
        startConversationLabel: String = "Start voice conversation",
        endConversationLabel: String = "End conversation",
        muteMicrophoneLabel: String = "Mute microphone",
        unmuteMicrophoneLabel: String = "Unmute microphone"
    ) {
        self.title = title
        self.mainLabel = mainLabel
        self.inputPlaceholder = inputPlaceholder
        self.openChatLabel = openChatLabel
        self.closeChatLabel = closeChatLabel
        self.sendMessageLabel = sendMessageLabel
        self.startConversationLabel = startConversationLabel
        self.endConversationLabel = endConversationLabel
        self.muteMicrophoneLabel = muteMicrophoneLabel
        self.unmuteMicrophoneLabel = unmuteMicrophoneLabel
    }

    public static let `default` = ChatWidgetStrings()
}
#endif
