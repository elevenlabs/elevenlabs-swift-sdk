import Foundation

protocol TokenServicing: Sendable {
    /// Fetch connection details for ElevenLabs conversation
    /// - Parameter credentials: The credentials to authenticate with
    func fetchConnectionDetails(
        credentials: ConversationCredentials
    ) async throws -> TokenService.ConnectionDetails
}

extension TokenService: TokenServicing {}
