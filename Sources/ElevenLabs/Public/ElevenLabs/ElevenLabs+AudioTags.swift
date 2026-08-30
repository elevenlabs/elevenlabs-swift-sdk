import Foundation

extension ElevenLabs {
    /// Removes Eleven v3 audio tags from text intended for display.
    ///
    /// Voice responses can contain tags such as `[laughs]` and `[clears throat]`
    /// that control speech delivery. This helper removes those tags while
    /// preserving Markdown links such as `[docs](https://example.com)`.
    ///
    /// The SDK keeps response events and `Message.content` unchanged. Apply this
    /// helper only when presenting voice transcripts; text-only responses can
    /// contain bracketed text that should remain visible.
    public static func stripAudioTags(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\[[A-Za-z0-9_\s]+\](?!\()\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
