import Foundation

/// Why a conversation failed. Each case needs a different response from the app; a connection failure also says what broke.
public enum ConversationError: LocalizedError, Sendable, Equatable {
    /// The credentials were refused; get new ones or fix the configuration.
    case authenticationFailed(String)
    /// The conversation couldn't be established; retrying may help.
    case connectionFailed(ConnectionFailure, String)
    /// The microphone couldn't be enabled or toggled.
    case microphoneFailed(String)
    /// A command was issued with no live conversation.
    case notConnected
    /// The server reported an error during the conversation.
    case serverError(ErrorEvent)

    /// What broke while establishing a conversation.
    public enum ConnectionFailure: Sendable, Equatable {
        /// Couldn't get a token: a network error, request timeout, or malformed response.
        case tokenRequestFailed
        /// The token service is busy or failing (429, 5xx).
        case tokenServiceUnavailable
        /// Couldn't connect the voice room.
        case roomConnectionFailed
        /// The agent didn't join in time.
        case agentDidNotJoin
        /// Connected, but couldn't start the conversation; for text, the socket didn't open.
        case initializationFailed
        /// The server didn't confirm the conversation in time.
        case initializationTimedOut
    }

    public var errorDescription: String? {
        switch self {
        case let .authenticationFailed(message): "Authentication failed: \(message)"
        case let .connectionFailed(_, message): "Connection failed: \(message)"
        case let .microphoneFailed(message): "Microphone failed: \(message)"
        case .notConnected: "Conversation is not connected."
        case let .serverError(event): "Server error (\(event.code)): \(event.message ?? "unknown")"
        }
    }
}
