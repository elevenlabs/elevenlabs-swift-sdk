#if os(iOS)
import Foundation

/// User-facing copy for ``ChatWidget``. Override individual fields to localize
/// or reword; every field has an English default.
public struct ChatWidgetStrings: Equatable, Sendable {
    public var title: String
    public var mainLabel: String
    public var inputPlaceholder: String
    public var openChatLabel: String
    public var closeChatLabel: String
    public var expandChatLabel: String
    public var collapseChatLabel: String
    public var sendMessageLabel: String
    public var startConversationLabel: String
    public var endConversationLabel: String
    public var muteMicrophoneLabel: String
    public var unmuteMicrophoneLabel: String
    public var userEndedConversation: String
    public var agentEndedConversation: String
    public var conversationIdFormat: String
    public var conversationStartFailed: String
    public var conversationFailed: String
    public var messageSendFailed: String
    public var microphonePermissionDenied: String
    public var openSettingsLabel: String
    public var dismissLabel: String

    public init(
        title: String = "Chat",
        mainLabel: String = "Powered by ElevenLabs",
        inputPlaceholder: String = "Type a message…",
        openChatLabel: String = "Open chat",
        closeChatLabel: String = "Close chat",
        expandChatLabel: String = "Expand chat",
        collapseChatLabel: String = "Collapse chat",
        sendMessageLabel: String = "Send message",
        startConversationLabel: String = "Start voice conversation",
        endConversationLabel: String = "End conversation",
        muteMicrophoneLabel: String = "Mute microphone",
        unmuteMicrophoneLabel: String = "Unmute microphone",
        userEndedConversation: String = "You ended the conversation.",
        agentEndedConversation: String = "The agent ended the conversation.",
        conversationIdFormat: String = "Conversation ID: %@",
        conversationStartFailed: String = "The conversation couldn't be started.",
        conversationFailed: String = "The conversation ran into a problem.",
        messageSendFailed: String = "That message couldn't be sent.",
        microphonePermissionDenied: String = "Microphone access is off, so the agent can't hear you.",
        openSettingsLabel: String = "Settings",
        dismissLabel: String = "Dismiss"
    ) {
        self.title = title
        self.mainLabel = mainLabel
        self.inputPlaceholder = inputPlaceholder
        self.openChatLabel = openChatLabel
        self.closeChatLabel = closeChatLabel
        self.expandChatLabel = expandChatLabel
        self.collapseChatLabel = collapseChatLabel
        self.sendMessageLabel = sendMessageLabel
        self.startConversationLabel = startConversationLabel
        self.endConversationLabel = endConversationLabel
        self.muteMicrophoneLabel = muteMicrophoneLabel
        self.unmuteMicrophoneLabel = unmuteMicrophoneLabel
        self.userEndedConversation = userEndedConversation
        self.agentEndedConversation = agentEndedConversation
        self.conversationIdFormat = conversationIdFormat
        self.conversationStartFailed = conversationStartFailed
        self.conversationFailed = conversationFailed
        self.messageSendFailed = messageSendFailed
        self.microphonePermissionDenied = microphonePermissionDenied
        self.openSettingsLabel = openSettingsLabel
        self.dismissLabel = dismissLabel
    }

    public static let `default` = ChatWidgetStrings()
}
#endif
