import Foundation

extension ElevenLabs {
    /// Global SDK configuration.
    public struct Configuration: Sendable {
        public let logLevel: LogLevel
        public let debugMode: Bool

        public init(
            logLevel: LogLevel = .warning,
            debugMode: Bool = false
        ) {
            self.logLevel = logLevel
            self.debugMode = debugMode
        }

        public static let `default` = Configuration()

        /// Create a new configuration with updated values (builder pattern)
        public func with(
            logLevel: LogLevel? = nil,
            debugMode: Bool? = nil
        ) -> Configuration {
            Configuration(
                logLevel: logLevel ?? self.logLevel,
                debugMode: debugMode ?? self.debugMode
            )
        }
    }
}
