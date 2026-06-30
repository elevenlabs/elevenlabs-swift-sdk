import Foundation

protocol TokenServicing: Sendable {
    /// Fetch a LiveKit room token for an ElevenLabs conversation.
    /// - Parameters:
    ///   - auth: The configuration to use for fetching the token.
    ///   - apiBase: Base host the conversation-token endpoint is derived from.
    ///   - environment: Optional environment for the conversation-token request
    ///     (from `ConversationConfig.environment`).
    /// - Returns: The participant token for the ElevenLabs conversation.
    func fetchRoomToken(auth: ConversationAuth, apiBase: URL, environment: String?) async throws -> String
}

// MARK: - Token Service

/// Stateless service for obtaining ElevenLabs auth tokens: public agents mint a
/// room token from the API; otherwise a conversation token from your backend is
/// used directly.
///
/// SECURITY: never ship an ElevenLabs API key in a client app — use public
/// agents or a backend endpoint that generates conversation tokens.
public struct TokenService: TokenServicing, Sendable {
    private let urlSession: URLSession

    // Development-only API key for testing private agents
    // This should only be set in debug builds for local testing
    #if DEBUG
    private static let debugLogger: any Logging = SDKLogger()
    public let debugApiKey: String?

    public init(
        urlSession: URLSession = .shared,
        debugApiKey: String? = nil
    ) {
        self.urlSession = urlSession
        self.debugApiKey = debugApiKey
    }
    #else
    public init(
        urlSession: URLSession = .shared
    ) {
        self.urlSession = urlSession
    }
    #endif

    /// Fetch a LiveKit room token for an ElevenLabs conversation.
    public func fetchRoomToken(
        auth: ConversationAuth,
        apiBase: URL,
        environment: String? = nil
    ) async throws -> String {
        switch auth.authSource {
        case let .publicAgentId(agentId):
            return try await fetchRoomTokenFromElevenlabsAPI(
                agentId: agentId,
                apiBase: apiBase,
                environment: environment
            )
        case let .conversationToken(conversationToken):
            return conversationToken
        case .signedWebSocketURL:
            throw ConversationError.authenticationFailed("Signed WebSocket URLs are only supported for text-only conversations.")
        }
    }

    /// Mint a room token for a public agent. The HTTP request itself is routed
    /// through ``ConversationRESTClient`` so all conversation HTTP lives in one
    /// place; this method owns the auth-source selection and the DEBUG-only API
    /// key policy.
    private func fetchRoomTokenFromElevenlabsAPI(
        agentId: String,
        apiBase: URL,
        environment: String?
    ) async throws -> String {
        let restClient = ConversationRESTClient(apiBase: apiBase, urlSession: urlSession)

        // DEBUG-only: forward an API key for private-agent testing (never shipped).
        #if DEBUG
        if debugApiKey != nil {
            Self.debugLogger.warning("Using API key in client - DEVELOPMENT ONLY!")
            Self.debugLogger.warning("For production, implement a backend service to generate tokens")
        }
        return try await restClient.fetchConversationToken(
            agentId: agentId,
            environment: environment,
            debugApiKey: debugApiKey
        )
        #else
        return try await restClient.fetchConversationToken(
            agentId: agentId,
            environment: environment,
            debugApiKey: nil
        )
        #endif
    }
}

/// Error types for token-related issues
enum TokenError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case authenticationFailed
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL for token request"
        case .invalidResponse:
            "Invalid response from server"
        case let .httpError(code):
            "HTTP error: \(code)"
        case .authenticationFailed:
            "Authentication failed - agent may be private." +
                " For private agents, use a conversation token from your backend instead of connecting directly."
        case .invalidTokenResponse:
            "Invalid token in response"
        }
    }
}
