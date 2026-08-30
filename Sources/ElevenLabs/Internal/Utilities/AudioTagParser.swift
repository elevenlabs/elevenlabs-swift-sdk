import Foundation

enum AudioTagParser {
    static func strip(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\[[A-Za-z0-9_\s]+\](?!\()\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
