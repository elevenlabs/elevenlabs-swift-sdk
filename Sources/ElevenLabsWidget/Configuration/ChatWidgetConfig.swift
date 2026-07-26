#if canImport(UIKit)
import Foundation

/// Behavior and appearance of ``ChatWidget``.
public struct ChatWidgetConfig: Equatable, Sendable {
    /// Whether the user talks, types, or both.
    public var conversationMode: WidgetConversationMode
    /// Dim the host UI behind the open drawer.
    public var showBackdrop: Bool
    /// Show the microphone mute button while a conversation is live.
    public var enableMicMuteControl: Bool
    public var strings: ChatWidgetStrings
    public var theme: ChatWidgetTheme

    public init(
        conversationMode: WidgetConversationMode = .voiceAndText,
        showBackdrop: Bool = true,
        enableMicMuteControl: Bool = true,
        strings: ChatWidgetStrings = .default,
        theme: ChatWidgetTheme = .default
    ) {
        self.conversationMode = conversationMode
        self.showBackdrop = showBackdrop
        self.enableMicMuteControl = enableMicMuteControl
        self.strings = strings
        self.theme = theme
    }

    public static let `default` = ChatWidgetConfig()
}
#endif
