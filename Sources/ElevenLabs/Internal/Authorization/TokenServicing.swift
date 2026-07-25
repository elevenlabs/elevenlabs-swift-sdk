import Foundation

protocol TokenServicing: Sendable {
    /// Resolve the token a voice conversation authenticates with.
    /// - Parameter credentials: The credentials to authenticate with
    func fetchToken(for credentials: ConversationCredentials) async throws -> String
}

extension TokenService: TokenServicing {}
