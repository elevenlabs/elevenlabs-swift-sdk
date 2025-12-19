import Foundation
import OSLog

/// Internal logger for SDK diagnostics using os.Logger
protocol Logging: Sendable {
    func trace(_ message: String, context: [String: String]?)
    func debug(_ message: String, context: [String: String]?)
    func info(_ message: String, context: [String: String]?)
    func warning(_ message: String, context: [String: String]?)
    func error(_ message: String, context: [String: String]?)
}

extension Logging {
    func trace(_ message: String) { trace(message, context: nil) }
    func debug(_ message: String) { debug(message, context: nil) }
    func info(_ message: String) { info(message, context: nil) }
    func warning(_ message: String) { warning(message, context: nil) }
    func error(_ message: String) { error(message, context: nil) }
}

/// Default logger implementation
/// Default logger implementation using `os_log` for broad compatibility (iOS 13+)
struct SDKLogger: Logging {
    private let subsystem: String
    private let category: String
    private let logLevel: ElevenLabs.LogLevel

    init(
        subsystem: String = "com.elevenlabs.sdk",
        category: String = "ElevenLabs",
        logLevel: ElevenLabs.LogLevel = .info
    ) {
        self.subsystem = subsystem
        self.category = category
        self.logLevel = logLevel
    }
    
    // Helper to log safely
    private func log(_ message: String, type: OSLogType, context: [String: String]?) {
        let prefix = "[ElevenLabs]"
        let finalMessage: String
        if let context = context, !context.isEmpty {
            let contextString = context.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            finalMessage = "\(prefix) [\(contextString)] \(message)"
        } else {
            finalMessage = "\(prefix) \(message)"
        }

        if #available(iOS 14.0, macOS 11.0, *) {
            let logger = os.Logger(subsystem: subsystem, category: category)
            logger.log(level: type, "\(finalMessage)")
        } else {
            let log = OSLog(subsystem: subsystem, category: category)
            os_log(type, log: log, "%{public}@", finalMessage)
        }
    }

    func trace(_ message: String, context: [String: String]? = nil) {
        guard logLevel >= .trace else { return }
        log(message, type: .debug, context: context)
    }

    func debug(_ message: String, context: [String: String]? = nil) {
        guard logLevel >= .debug else { return }
        log(message, type: .debug, context: context)
    }

    func info(_ message: String, context: [String: String]? = nil) {
        guard logLevel >= .info else { return }
        log(message, type: .info, context: context)
    }

    func warning(_ message: String, context: [String: String]? = nil) {
        guard logLevel >= .warning else { return }
        log(message, type: .default, context: context)
    }

    func error(_ message: String, context: [String: String]? = nil) {
        guard logLevel >= .error else { return }
        log(message, type: .error, context: context)
    }
}
