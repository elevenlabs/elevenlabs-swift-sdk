import Foundation

/// Answers a client tool call. See `ConversationCallbacks.onClientToolCall`.
public typealias ClientToolHandler = @MainActor @Sendable (ClientToolCallEvent) async throws -> ClientToolReply

/// Builds a `ClientToolHandler` from one handler for each tool.
public enum ClientTools {
    /// Returns a handler that runs the handler for the call's tool name. A call for a
    /// tool that `tools` doesn't have gets an error result, so the agent doesn't wait for it.
    public static func handler(_ tools: [String: ClientToolHandler]) -> ClientToolHandler {
        { call in
            guard let tool = tools[call.toolName] else {
                throw ClientToolError("No client tool named \(call.toolName) is registered in this app.")
            }
            return try await tool(call)
        }
    }
}

/// What a `ClientToolHandler` does with a call.
public enum ClientToolReply: Sendable, Equatable {
    /// Sends this text to the agent as the tool's result.
    case result(String)

    /// Leaves the call in `ConversationClient.pendingToolCalls`, for the app to answer later
    /// with `sendToolResult` or `markToolCallCompleted`.
    case pending

    /// Sends `value` to the agent as JSON. Dates are encoded in ISO 8601.
    public static func result(json value: some Encodable) throws -> ClientToolReply {
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
