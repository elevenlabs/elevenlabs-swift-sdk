import Foundation

extension ElevenLabs {
    /// Logging level for SDK internal diagnostics
    public enum LogLevel: Int, Comparable, Sendable {
        case error = 0
        case warning = 1
        case info = 2
        case debug = 3
        case trace = 4

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}
