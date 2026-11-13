import Foundation

/// Answers a client tool call. See `ConversationCallbacks.onClientToolCall`.
public typealias ClientToolHandler = @MainActor @Sendable (ClientToolCallEvent) async throws -> ClientToolReply

/// What a `ClientToolHandler` does with a call.
public enum ClientToolReply: Sendable, Equatable {
    /// Sends this text to the agent as the tool's result.
    case result(String)

    /// Leaves the call in `ConversationClient.pendingToolCalls`, for the app to answer later
    /// with `sendToolResult` or `markToolCallCompleted`.
    case later

    /// Sends `value` to the agent as JSON. Dates are encoded in ISO 8601.
    public static func json(_ value: some Encodable) throws -> ClientToolReply {
        try .result(ClientToolResultEvent.json(value))
    }
}

/// Thrown by a `ClientToolHandler` to send `message` to the agent as an error result.
public struct ClientToolError: LocalizedError, Sendable, Equatable {
    /// Text the agent sees as the tool's result.
    public let message: String

    /// The kind of failure, which the agent can react to, such as `.userRejected`.
    public let errorType: ClientToolErrorType?

    public init(_ message: String, errorType: ClientToolErrorType? = nil) {
        self.message = message
        self.errorType = errorType
    }

    public var errorDescription: String? {
        message
    }
}
