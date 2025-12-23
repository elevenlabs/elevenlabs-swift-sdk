import Foundation
import LiveKit

/// Step responsible for establishing LiveKit room connection
final class RoomConnectionStep: StartupStep {
    let stepName = "Room Connection"

    private let connectionManager: any ConnectionManaging
    private let details: TokenService.ConnectionDetails
    private let enableMic: Bool
    private let throwOnMicrophoneFailure: Bool
    private let networkConfiguration: LiveKitNetworkConfiguration
    private let graceTimeout: TimeInterval
    private let logger: any Logging

    init(
        connectionManager: any ConnectionManaging,
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool = true,
        networkConfiguration: LiveKitNetworkConfiguration,
        graceTimeout: TimeInterval,
        logger: any Logging
    ) {
        self.connectionManager = connectionManager
        self.details = details
        self.enableMic = enableMic
        self.throwOnMicrophoneFailure = throwOnMicrophoneFailure
        self.networkConfiguration = networkConfiguration
        self.graceTimeout = graceTimeout
        self.logger = logger
    }

    func execute() async throws {
        logger.debug("Starting room connection...")

        do {
            try await connectionManager.connect(
                details: details,
                enableMic: enableMic,
                throwOnMicrophoneFailure: throwOnMicrophoneFailure,
                networkConfiguration: networkConfiguration,
                graceTimeout: graceTimeout
            )
            logger.debug("Room connection successful")
        } catch let error as ConversationError {
            throw error
        } catch {
            throw ConversationError.connectionFailed(error)
        }
    }
}
