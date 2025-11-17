@testable import ElevenLabs
import Foundation

@MainActor
final class MockTokenService {
    enum Scenario {
        case success
        case authenticationFailed(String)
        case httpError(Int)
        case arbitrary(Error)
    }

    var scenario: Scenario = .success
    var mockConnectionDetails: TokenService.ConnectionDetails?

    static func makeSuccessResponse() -> TokenService.ConnectionDetails {
        TokenService.ConnectionDetails(
            serverUrl: "wss://livekit.rtc.elevenlabs.io",
            roomName: "test-room",
            participantName: "test-user",
            participantToken: "mock-token"
        )
    }
}

extension MockTokenService: TokenServicing {
    func fetchConnectionDetails(configuration _: ElevenLabsConfiguration) async throws -> TokenService.ConnectionDetails {
        switch scenario {
        case .success:
            return mockConnectionDetails ?? MockTokenService.makeSuccessResponse()
        case let .authenticationFailed(message):
            throw ConversationError.authenticationFailed(message)
        case let .httpError(code):
            throw ConversationError.connectionFailed("HTTP error: \(code)")
        case let .arbitrary(error):
            throw error
        }
    }
}
