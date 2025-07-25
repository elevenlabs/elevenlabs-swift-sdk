import Foundation

/// A service for fetching ElevenLabs authentication tokens
///
/// This service supports two authentication methods:
/// 1. Public Agent ID - Fetches a token from ElevenLabs API using a public agent ID
/// 2. Conversation Token - Uses a pre-generated conversation token from your backend
///
/// ⚠️ SECURITY WARNING:
/// NEVER include your ElevenLabs API key in a client application!
/// API keys should only be used server-side. For production apps:
/// - Use public agents (no authentication required)
/// - OR implement a backend endpoint that generates conversation tokens

enum ConnectionConstants {
    static let wssUrl = "wss://livekit.rtc.elevenlabs.io"
    static let tokenUrl = "https://api.elevenlabs.io/v1/convai/conversation/token"
}

// MARK: - Public SDK API

/// Configuration for ElevenLabs conversational AI
public struct ElevenLabsConfiguration: Sendable {
    /// The source of authentication for the conversation
    public enum AuthSource: Sendable {
        /// Use a public agent ID (no authentication required)
        case publicAgentId(String)
        /// Use a conversation token from your backend
        case conversationToken(String)
        /// Custom token provider for advanced use cases
        case customTokenProvider(@Sendable () async throws -> String)
    }

    public let authSource: AuthSource
    public let participantName: String

    /// Initialize with a public agent ID
    public static func publicAgent(id: String, participantName: String = "user") -> Self {
        .init(authSource: .publicAgentId(id), participantName: participantName)
    }

    /// Initialize with a conversation token
    public static func conversationToken(_ token: String, participantName: String = "user") -> Self {
        .init(authSource: .conversationToken(token), participantName: participantName)
    }

    /// Initialize with a custom token provider
    public static func customTokenProvider(_ provider: @escaping @Sendable () async throws -> String, participantName: String = "user") -> Self {
        .init(authSource: .customTokenProvider(provider), participantName: participantName)
    }
}

// MARK: - Token Service

/// Service for managing ElevenLabs authentication
/// This is designed to be stateless and SDK-friendly
public struct TokenService: Sendable {
    public struct ConnectionDetails: Codable, Sendable {
        public let serverUrl: String
        public let roomName: String
        public let participantName: String
        public let participantToken: String
    }

    /// Optional configuration for advanced use cases
    public struct Configuration: Sendable {
        /// Custom API endpoint (for testing or enterprise deployments)
        public let apiEndpoint: String?
        /// Custom WebSocket URL (for testing or enterprise deployments)
        public let websocketURL: String?

        public init(apiEndpoint: String? = nil, websocketURL: String? = nil) {
            self.apiEndpoint = apiEndpoint
            self.websocketURL = websocketURL
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let urlSession: URLSession

    /// Development-only API key for testing private agents
    /// This should only be set in debug builds for local testing
    #if DEBUG
        public let debugApiKey: String?

        public init(
            configuration: Configuration = .default,
            urlSession: URLSession = .shared,
            debugApiKey: String? = nil,
        ) {
            self.configuration = configuration
            self.urlSession = urlSession
            self.debugApiKey = debugApiKey
        }
    #else
        public init(
            configuration: Configuration = .default,
            urlSession: URLSession = .shared,
        ) {
            self.configuration = configuration
            self.urlSession = urlSession
        }
    #endif

    /// Fetch connection details for ElevenLabs conversation
    public func fetchConnectionDetails(configuration: ElevenLabsConfiguration) async throws -> ConnectionDetails {
        let token: String = switch configuration.authSource {
        case let .publicAgentId(agentId):
            try await fetchTokenFromAPI(agentId: agentId)
        case let .conversationToken(conversationToken):
            conversationToken
        case let .customTokenProvider(provider):
            try await provider()
        }

        // ElevenLabs tokens contain room name and participant identity in the JWT
        // LiveKit will extract these automatically, so we provide empty values
        return ConnectionDetails(
            serverUrl: self.configuration.websocketURL ?? ConnectionConstants.wssUrl,
            roomName: "", // LiveKit extracts from JWT
            participantName: "", // LiveKit extracts from JWT
            participantToken: token,
        )
    }

    private func fetchTokenFromAPI(agentId: String) async throws -> String {
        // Build URL with agent ID as query parameter
        let apiUrl = configuration.apiEndpoint ?? ConnectionConstants.tokenUrl
        var components = URLComponents(string: apiUrl)!
        components.queryItems = [
            URLQueryItem(name: "agent_id", value: agentId),
            URLQueryItem(name: "source", value: "swift_sdk"),
            URLQueryItem(name: "version", value: SDKVersion.version),
        ]

        guard let url = components.url else {
            throw TokenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // ⚠️ DEVELOPMENT ONLY: Check for API key
        // This is ONLY for local development/testing. NEVER ship an app with an API key!
        #if DEBUG
            if let apiKey = debugApiKey {
                print("⚠️ WARNING: Using API key in client - DEVELOPMENT ONLY!")
                print("⚠️ For production, implement a backend service to generate tokens")
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

// MARK: - Errors

enum TokenError: LocalizedError, Sendable {
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
            "Authentication failed - agent may be private. For private agents, use a conversation token from your backend instead of connecting directly."
        case .invalidTokenResponse:
            "Invalid token in response"
        }
    }
}
