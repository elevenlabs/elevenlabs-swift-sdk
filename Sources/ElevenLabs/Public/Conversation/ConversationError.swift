import Foundation

public enum ConversationError: LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyActive
    /// A connection attempt failed. Carries a human-readable description (used for
    /// display and `Equatable`) and, when the failure originated from a
    /// system/transport error, the original error so callers can downcast it (e.g.
    /// to `URLError`) and branch on the cause. Read it via ``underlyingError``.
    case connectionFailed(String, UnderlyingError? = nil)
    case authenticationFailed(String)
    case agentTimeout
    /// The `conversation_initiation_client_data` handshake was not acknowledged
    /// with `conversation_initiation_metadata` within `conversationInitTimeout`.
    /// Distinct from `agentTimeout` (the voice room-join wait) and applies to
    /// both voice and text-only startup.
    case initializationTimeout
    /// Toggling the microphone failed. Carries a human-readable description and,
    /// when available, the original underlying error (read via ``underlyingError``).
    case microphoneToggleFailed(String, UnderlyingError? = nil)
    /// Microphone permission is denied/restricted and iOS will no longer prompt.
    /// The user must re-enable it from Settings.
    case microphonePermissionDenied
    case serverError(ErrorEvent)
    /// A client tool result value could not be encoded. It was neither a
    /// `String`, a JSON object/array, nor a numeric/boolean scalar — return one
    /// of those instead of an arbitrary type. The associated value names the
    /// offending type.
    case invalidToolResult(String)
    /// Failed to build a valid request URL.
    case invalidURL

    /// Wrap a system/transport `Error`, preserving both its localized description
    /// (for display + `Equatable`) and the original error (for programmatic
    /// inspection via ``underlyingError``).
    public static func connectionFailed(_ error: Error) -> ConversationError {
        .connectionFailed(error.localizedDescription, UnderlyingError(error))
    }

    public static func microphoneToggleFailed(_ error: Error) -> ConversationError {
        .microphoneToggleFailed(error.localizedDescription, UnderlyingError(error))
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Conversation is not connected."
        case .alreadyActive: "Conversation is already active."
        case let .connectionFailed(description, _): "Connection failed: \(description)"
        case let .authenticationFailed(msg): "Authentication failed: \(msg)"
        case .agentTimeout: "Agent did not join in time."
        case .initializationTimeout: "The conversation initialization handshake was not acknowledged in time."
        case let .microphoneToggleFailed(description, _): "Failed to toggle microphone: \(description)"
        case .microphonePermissionDenied: "Microphone access is off. Enable it in Settings to start a voice conversation."
        case let .serverError(event): "Server error (\(event.code)): \(event.message ?? "unknown")"
        case let .invalidToolResult(detail): "Invalid tool result: \(detail)"
        case .invalidURL: "Could not build a valid request URL."
        }
    }

    /// The original system/transport error behind a wrapped failure, if one was
    /// captured. Non-`nil` only for ``connectionFailed`` and
    /// ``microphoneToggleFailed`` values built from an `Error`. Downcast it to a
    /// concrete type (e.g. `URLError`) to branch on the underlying cause instead
    /// of string-matching the (localized) description.
    public var underlyingError: (any Error)? {
        switch self {
        case let .connectionFailed(_, cause), let .microphoneToggleFailed(_, cause):
            cause?.error
        default:
            nil
        }
    }

    /// `Equatable` + `Sendable` box around an underlying `Error` so the wrapped
    /// cases keep `ConversationError`'s auto-synthesized conformances. Errors are
    /// treated as immutable (hence `@unchecked Sendable`), and any two boxes compare
    /// equal — so equality stays driven by the case's description string.
    public struct UnderlyingError: @unchecked Sendable, Equatable {
        public let error: any Error
        public init(_ error: any Error) { self.error = error }
        public static func == (_: Self, _: Self) -> Bool { true }
    }
}
