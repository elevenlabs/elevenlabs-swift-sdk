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

    /// Resolve the token a voice conversation authenticates with.
    ///
    /// Translates internal `TokenError`s into public `ConversationError`s so
    /// callers only ever deal with one error type.
    func fetchToken(for auth: ConversationAuth.Voice, environment: String?) async throws -> String {
        do {
            switch auth {
            case let .publicAgent(agentId):
                return try await fetchTokenFromAPI(agentId: agentId, environment: environment)
            case let .conversationToken(mint):
                return try await mint()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ConversationError {
            throw error
        } catch let error as TokenError {
            throw ConversationError.authenticationFailed(error)
        } catch {
            throw ConversationError.connectionFailed(error)
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
            throw TokenError.invalidURL
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
            throw TokenError.invalidURL
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

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokenError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw TokenError.authenticationFailed
            }
            throw TokenError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse response - ElevenLabs returns {"token": "..."}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty
        else {
            throw TokenError.invalidTokenResponse
        }

        return token
    }
}
