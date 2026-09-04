import Foundation

public struct ConversationErrorDetails: Sendable, Equatable {
    public let message: String
    public let underlyingError: (any Error)?

    public init(message: String, underlyingError: (any Error)? = nil) {
        self.message = message
        self.underlyingError = underlyingError
    }

    public init(_ underlyingError: any Error) {
        self.init(message: underlyingError.localizedDescription, underlyingError: underlyingError)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
    }
}

public enum ConversationError: LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyStarted
    case connectionFailed(ConversationErrorDetails)
    case authenticationFailed(ConversationErrorDetails)
    case agentTimeout
    case initiationMetadataTimeout
    case microphoneToggleFailed(String) // Store error description instead of Error for Equatable
    case serverError(ErrorEvent)

    public static func connectionFailed(_ message: String) -> ConversationError {
        .connectionFailed(.init(message: message))
    }

    public static func connectionFailed(_ error: Error) -> ConversationError {
        .connectionFailed(.init(error))
    }

    public static func authenticationFailed(_ message: String) -> ConversationError {
        .authenticationFailed(.init(message: message))
    }

    public static func authenticationFailed(_ error: Error) -> ConversationError {
        .authenticationFailed(.init(error))
    }

    public static func microphoneToggleFailed(_ error: Error) -> ConversationError {
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
        case let .microphoneToggleFailed(description): "Failed to toggle microphone: \(description)"
        case let .serverError(event): "Server error (\(event.code)): \(event.message ?? "unknown")"
        }
    }
}
