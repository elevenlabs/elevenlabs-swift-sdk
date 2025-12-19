import Foundation

/// Step responsible for fetching authentication token and connection details
final class TokenResolutionStep: StartupStep {
    let stepName = "Token Resolution"
    
    private let tokenService: any TokenServicing
    private let auth: ElevenLabsConfiguration
    private let logger: any Logging
    private let onResult: (TokenService.ConnectionDetails) -> Void
    
    init(
        tokenService: any TokenServicing,
        auth: ElevenLabsConfiguration,
        logger: any Logging,
        onResult: @escaping (TokenService.ConnectionDetails) -> Void
    ) {
        self.tokenService = tokenService
        self.auth = auth
        self.logger = logger
        self.onResult = onResult
    }
    
    func execute() async throws {
        logger.debug("Fetching token/connection details...")
        
        do {
            let details = try await tokenService.fetchConnectionDetails(configuration: auth)
            onResult(details)
            logger.debug("Token fetch successful")
        } catch let error as ConversationError {
            throw error
        } catch let error as TokenError {
            let conversationError: ConversationError = switch error {
            case .authenticationFailed:
                .authenticationFailed(error.localizedDescription)
            case let .httpError(statusCode):
                .authenticationFailed("HTTP error: \(statusCode)")
            case .invalidURL, .invalidResponse, .invalidTokenResponse:
                .authenticationFailed(error.localizedDescription)
            }
            throw conversationError
        } catch {
            throw ConversationError.connectionFailed(error)
        }
    }
}
