import Foundation

public enum ConversationError: LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyStarted
    case connectionFailed(String) // Store error description instead of Error for Equatable
    case authenticationFailed(String)
    case agentTimeout
    case initiationMetadataTimeout
    case microphoneToggleFailed(String) // Store error description instead of Error for Equatable
    case serverError(ErrorEvent)

    /// Helper methods to create errors with Error types
    public static func connectionFailed(_ error: Error) -> ConversationError {
        .connectionFailed(error.localizedDescription)
    }

    public static func microphoneToggleFailed(_ error: Error) -> ConversationError {
        .microphoneToggleFailed(error.localizedDescription)
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Conversation is not connected."
        case .alreadyStarted: "Conversation has already been started."
        case let .connectionFailed(description): "Connection failed: \(description)"
        case let .authenticationFailed(msg): "Authentication failed: \(msg)"
        case .agentTimeout: "Agent did not join in time."
        case .initiationMetadataTimeout: "Conversation metadata was not received in time."
        case let .microphoneToggleFailed(description): "Failed to toggle microphone: \(description)"
        case let .serverError(event): "Server error (\(event.code)): \(event.message ?? "unknown")"
        }
    }
}
