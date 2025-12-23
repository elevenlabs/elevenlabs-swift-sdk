import Foundation

extension ElevenLabs {
    /// Global SDK configuration.
    public struct Configuration: Sendable {
        public let apiEndpoint: URL?
        public let websocketUrl: String?
        public let logLevel: LogLevel
        public let debugMode: Bool

        public init(
            apiEndpoint: URL? = nil,
            websocketUrl: String? = nil,
            logLevel: LogLevel = .warning,
            debugMode: Bool = false
        ) {
            self.apiEndpoint = apiEndpoint
            self.websocketUrl = websocketUrl
            self.logLevel = logLevel
            self.debugMode = debugMode
        }

        public static let `default` = Configuration()

        /// Create a new configuration with updated values (builder pattern)
        public func with(
            apiEndpoint: URL? = nil,
            websocketUrl: String? = nil,
            logLevel: LogLevel? = nil,
            debugMode: Bool? = nil
        ) -> Configuration {
            Configuration(
                apiEndpoint: apiEndpoint ?? self.apiEndpoint,
                websocketUrl: websocketUrl ?? self.websocketUrl,
                logLevel: logLevel ?? self.logLevel,
                debugMode: debugMode ?? self.debugMode
            )
        }
    }
}
