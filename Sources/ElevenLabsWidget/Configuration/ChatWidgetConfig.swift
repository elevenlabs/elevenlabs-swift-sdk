#if os(iOS)
import Foundation

/// Behavior and appearance of ``ChatWidget``.
public struct ChatWidgetConfig: Equatable, Sendable {
    /// Dim the host UI behind the open drawer.
    public var showBackdrop: Bool
    /// Show the microphone mute button while a conversation is live.
    public var enableMicMuteControl: Bool
    public var strings: ChatWidgetStrings
    public var theme: ChatWidgetTheme

    public init(
        showBackdrop: Bool = true,
        enableMicMuteControl: Bool = true,
        strings: ChatWidgetStrings = .default,
        theme: ChatWidgetTheme = .default
    ) {
        self.showBackdrop = showBackdrop
        self.enableMicMuteControl = enableMicMuteControl
        self.strings = strings
        self.theme = theme
    }

    public static let `default` = ChatWidgetConfig()
}
#endif
