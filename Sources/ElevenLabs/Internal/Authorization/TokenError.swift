import Foundation

/// Error types for token-related issues
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
            "Authentication failed - agent may be private." +
                " For private agents, use a conversation token from your backend instead of connecting directly."
        case .invalidTokenResponse:
            "Invalid token in response"
        }
    }
}
