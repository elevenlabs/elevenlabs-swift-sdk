import Foundation

// A service for fetching ElevenLabs authentication tokens
//
// This service supports two authentication methods:
// 1. Public Agent ID - Fetches a token from ElevenLabs API using a public agent ID
// 2. Conversation Token - Uses a pre-generated conversation token from your backend
//
// SECURITY NOTE:
// NEVER include your ElevenLabs API key in a client application!
// API keys should only be used server-side. For production apps:
// - Use public agents (no authentication required)
// - OR implement a backend endpoint that generates conversation tokens

// MARK: - Token Service

/// Service for managing ElevenLabs authentication
/// This is designed to be stateless and SDK-friendly
struct TokenService: Sendable {
    private let endpoints: Endpoints
    private let urlSession: URLSession

    // Development-only API key for testing private agents
    // This should only be set in debug builds for local testing
    #if DEBUG
    let debugApiKey: String?

    init(
        endpoints: Endpoints = .production,
        urlSession: URLSession = .shared,
        debugApiKey: String? = nil
    ) {
        self.endpoints = endpoints
        self.urlSession = urlSession
        self.debugApiKey = debugApiKey
    }
    #else
    init(
        endpoints: Endpoints = .production,
        urlSession: URLSession = .shared
    ) {
        self.endpoints = endpoints
        self.urlSession = urlSession
    }
    #endif

    /// Resolve the token a voice conversation authenticates with. Failures are `ConversationError`s.
    func fetchToken(for auth: ConversationAuth.Voice, environment: String?) async throws -> String {
        switch auth {
        case let .publicAgent(agentId):
            return try await fetchTokenFromAPI(agentId: agentId, environment: environment)
        case let .conversationToken(mint):
            do {
                return try await mint()
            } catch let error as ConversationError {
                throw error
            } catch {
                // Producing credentials is the closure's whole job, so any other failure is an authentication failure.
                throw ConversationError.authenticationFailed(error.localizedDescription)
            }
        }
    }

    private func fetchTokenFromAPI(
        agentId: String,
        environment: String? = nil
    ) async throws -> String {
        guard var components = URLComponents(
            url: endpoints.conversationToken,
            resolvingAgainstBaseURL: false
        ) else {
            throw ConversationError.authenticationFailed("Invalid URL for token request")
        }
        var queryItems = components.queryItems ?? []
        queryItems += [
            URLQueryItem(name: "agent_id", value: agentId),
            URLQueryItem(name: "source", value: "swift_sdk"),
            URLQueryItem(name: "version", value: version)
        ]
        if let environment {
            queryItems.append(URLQueryItem(name: "environment", value: environment))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ConversationError.authenticationFailed("Invalid URL for token request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // DEVELOPMENT ONLY: Check for API key
        // This is ONLY for local development/testing. NEVER ship an app with an API key!
        #if DEBUG
        if let apiKey = debugApiKey {
            let logger = SDKLogger(logLevel: .warning)
            logger.warning("Using API key in client - DEVELOPMENT ONLY!")
            logger.warning("For production, implement a backend service to generate tokens")
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        }
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ConversationError.connectionFailed(.tokenRequestFailed, error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConversationError.connectionFailed(.tokenRequestFailed, "Invalid response from the token endpoint")
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw ConversationError.authenticationFailed(
                "The agent may be private. For private agents, use a conversation token from your backend."
            )
        case 429, 500...:
            // The server said "not now", not "no": a retry can succeed.
            throw ConversationError.connectionFailed(.tokenServiceUnavailable, "Token request failed with HTTP \(httpResponse.statusCode)")
        default:
            throw ConversationError.authenticationFailed("Token request failed with HTTP \(httpResponse.statusCode)")
        }

        // Parse response - ElevenLabs returns {"token": "..."}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty
        else {
            throw ConversationError.connectionFailed(.tokenRequestFailed, "Invalid token in response")
        }

        return token
    }
}
