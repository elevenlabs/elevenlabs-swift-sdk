import Foundation
import LiveKit

/// Step responsible for establishing LiveKit room connection
final class RoomConnectionStep: StartupStep {
    let stepName = "Room Connection"

    private let webRTCConnectionManager: any WebRTCConnectionManaging
    private let details: TokenService.ConnectionDetails
    private let enableMic: Bool
    private let throwOnMicrophoneFailure: Bool
    private let networkConfiguration: LiveKitNetworkConfiguration
    private let logger: any Logging

    init(
        webRTCConnectionManager: any WebRTCConnectionManaging,
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool = true,
        networkConfiguration: LiveKitNetworkConfiguration,
        logger: any Logging
    ) {
        self.webRTCConnectionManager = webRTCConnectionManager
        self.details = details
        self.enableMic = enableMic
        self.throwOnMicrophoneFailure = throwOnMicrophoneFailure
        self.networkConfiguration = networkConfiguration
        self.logger = logger
    }

    func execute() async throws {
        logger.debug("Starting room connection...")

        do {
            try await webRTCConnectionManager.connect(
                details: details,
                enableMic: enableMic,
                throwOnMicrophoneFailure: throwOnMicrophoneFailure,
                networkConfiguration: networkConfiguration
            )
            logger.debug("Room connection successful")
        } catch let error as ConversationError {
            throw error
        } catch {
            throw ConversationError.connectionFailed(error)
        }
    }
}
