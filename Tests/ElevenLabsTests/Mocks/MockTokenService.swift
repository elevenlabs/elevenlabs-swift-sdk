@testable import ElevenLabs
import Foundation

final class MockTokenService {
    var shouldSucceed = true
    var mockConnectionDetails: TokenService.ConnectionDetails?
    var mockError: Error?

    static func makeSuccessResponse() -> TokenService.ConnectionDetails {
        TokenService.ConnectionDetails(
            serverUrl: "wss://livekit.rtc.elevenlabs.io",
            roomName: "test-room",
            participantName: "test-user",
            participantToken: "mock-token",
        )
    }

    static func makeFailureError() -> ConversationError {
        .authenticationFailed("Mock authentication failed")
    }
}

extension MockTokenService {
    func fetchConnectionDetails(configuration _: ElevenLabsConfiguration) async throws -> TokenService.ConnectionDetails {
        if !shouldSucceed {
            throw mockError ?? MockTokenService.makeFailureError()
        }

        return mockConnectionDetails ?? MockTokenService.makeSuccessResponse()
    }
}
