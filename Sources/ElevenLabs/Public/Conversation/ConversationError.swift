import Foundation

public enum ConversationError: LocalizedError, Sendable, Equatable {
    /// Why a connection, authentication or microphone step failed. Can gain fields without breaking callers.
    public struct Details: Sendable, Equatable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    case notConnected
    case alreadyStarted
    case connectionFailed(Details)
    case authenticationFailed(Details)
    case agentTimeout
    case initiationMetadataTimeout
    case microphoneToggleFailed(Details)
    case serverError(ErrorEvent)

    public static func connectionFailed(_ message: String) -> Self {
        .connectionFailed(Details(message))
    }

    public static func connectionFailed(_ error: Error) -> Self {
        .connectionFailed(error.localizedDescription)
    }

    public static func authenticationFailed(_ message: String) -> Self {
        .authenticationFailed(Details(message))
    }

    public static func microphoneToggleFailed(_ message: String) -> Self {
        .microphoneToggleFailed(Details(message))
    }

    public static func microphoneToggleFailed(_ error: Error) -> Self {
        .microphoneToggleFailed(error.localizedDescription)
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Conversation is not connected."
        case .alreadyStarted: "Conversation has already been started."
        case let .connectionFailed(details): "Connection failed: \(details.message)"
        case let .authenticationFailed(details): "Authentication failed: \(details.message)"
        case .agentTimeout: "Agent did not join in time."
        case .initiationMetadataTimeout: "Conversation metadata was not received in time."
        case let .microphoneToggleFailed(details): "Failed to toggle microphone: \(details.message)"
        case let .serverError(event): "Server error (\(event.code)): \(event.message ?? "unknown")"
        }
    }
}
