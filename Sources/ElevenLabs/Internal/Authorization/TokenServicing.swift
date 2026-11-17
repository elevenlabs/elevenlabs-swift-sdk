import Foundation

protocol TokenServicing: Sendable {
    /// Resolve the token a voice conversation authenticates with.
    func fetchToken(for auth: ConversationAuth.Voice, environment: String?) async throws -> String
}

extension TokenService: TokenServicing {}
