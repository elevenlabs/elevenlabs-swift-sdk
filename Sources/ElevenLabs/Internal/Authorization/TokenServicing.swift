import Foundation

protocol TokenServicing: Sendable {
    /// Resolve the token a voice conversation authenticates with.
    func fetchToken(for auth: ConversationAuth.Voice) async throws -> String
}

extension TokenService: TokenServicing {}
