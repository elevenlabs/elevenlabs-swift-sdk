import Foundation

protocol TokenServicing: Sendable {
    /// Fetch connection details for ElevenLabs conversation
    /// - Parameter configuration: The configuration to use for fetching connection details
    /// - Returns: The connection details for the ElevenLabs conversation
    func fetchConnectionDetails(configuration: ElevenLabsConfiguration) async throws -> TokenService.ConnectionDetails
}

extension TokenService: TokenServicing {}
