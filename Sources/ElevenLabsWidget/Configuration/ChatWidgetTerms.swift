#if canImport(UIKit)
import Foundation

/// Terms & conditions presented before a conversation starts when
/// ``ChatWidgetConfig/enableTermsAndConditions`` is on.
///
/// The body is rendered as markdown. Supply your own legal copy — the default
/// is a generic consent line and is not a substitute for your terms.
///
/// ```swift
/// let terms = ChatWidgetTerms(
///     body: "By continuing you agree to our [Terms](https://example.com/terms)."
/// )
/// let config = ChatWidgetConfig(conversationMode: .voiceAndText, terms: terms)
/// ```
public struct ChatWidgetTerms: Equatable {
    /// Title shown at the top of the terms sheet.
    public var title: String

    /// Markdown body of the terms sheet.
    public var body: String

    /// Confirmation button that proceeds with starting the conversation.
    public var agreeButton: String

    /// Button that dismisses the sheet and aborts the start.
    public var cancelButton: String

    public init(
        title: String = "Terms & conditions",
        body: String = "By continuing, you consent to the recording, storage, and "
            + "processing of your audio and messages as described in our privacy policy.",
        agreeButton: String = "I agree",
        cancelButton: String = "Cancel"
    ) {
        self.title = title
        self.body = body
        self.agreeButton = agreeButton
        self.cancelButton = cancelButton
    }

    public static let `default` = ChatWidgetTerms()
}

#endif
