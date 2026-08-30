import Foundation

enum AudioTagRemover {
    static func remove(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\[[A-Za-z0-9_\s]+\](?!\()\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
