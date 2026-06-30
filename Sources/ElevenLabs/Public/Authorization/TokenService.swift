import Foundation

// MARK: - Token Service

/// Stateless service for obtaining ElevenLabs auth tokens: public agents mint a
/// room token from the API; otherwise a conversation token from your backend is
/// used directly.
///
/// SECURITY: never ship an ElevenLabs API key in a client app — use public
/// agents or a backend endpoint that generates conversation tokens.
public struct TokenService: TokenServicing, Sendable {
    /// Path of the conversation-token endpoint, relative to `apiBase`.
    private static let conversationTokenPath = "/v1/convai/conversation/token"

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

    /// Mint a room token for a public agent via
    /// `GET /v1/convai/conversation/token?agent_id=…`. Throws ``TokenError``
    /// (mapped onto the user-facing `ConversationError` by the caller).
    ///
    /// `debugApiKey` forwards an `xi-api-key` for local private-agent testing;
    /// it is always `nil` in release builds — never ship a key.
    private func fetchRoomTokenFromElevenlabsAPI(
        agentId: String,
        apiBase: URL,
        environment: String?
    ) async throws -> String {
        // Join the token path onto apiBase, tolerating a trailing slash.
        guard var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            throw TokenError.invalidURL
        }
        let base = components.percentEncodedPath
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        components.percentEncodedPath = trimmedBase + Self.conversationTokenPath

        var queryItems = [
            URLQueryItem(name: "agent_id", value: agentId),
            URLQueryItem(name: "source", value: "swift_sdk"),
            URLQueryItem(name: "version", value: SDKVersion.version)
        ]
        if let environment {
            queryItems.append(URLQueryItem(name: "environment", value: environment))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw TokenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        #if DEBUG
        if let debugApiKey {
            Self.debugLogger.warning("Using API key in client - DEVELOPMENT ONLY!")
            Self.debugLogger.warning("For production, implement a backend service to generate tokens")
            request.setValue(debugApiKey, forHTTPHeaderField: "xi-api-key")
        }
        #endif

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TokenError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw TokenError.authenticationFailed
            }
            throw TokenError.httpError(statusCode: http.statusCode)
        }

        // ElevenLabs returns {"token": "..."}.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty
        else {
            throw TokenError.invalidTokenResponse
        }
        return token
    }
}
