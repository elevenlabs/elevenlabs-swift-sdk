#if canImport(UIKit)
import Foundation

/// Which ways the user can talk to the agent through ``ChatWidget``.
public enum WidgetConversationMode: String, CaseIterable, Identifiable, Sendable {
    /// Typed messages only; the conversation runs without audio.
    case textOnly
    /// A voice call with no composer.
    case voiceOnly
    /// A voice call the user can also type into.
    case voiceAndText

    public var id: String {
        rawValue
    }

    public var supportsVoice: Bool {
        self != .textOnly
    }

    public var supportsTextInput: Bool {
        self != .voiceOnly
    }
}
#endif
