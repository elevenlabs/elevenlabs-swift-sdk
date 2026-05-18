@testable import ElevenLabs
import Foundation
import LiveKit

final class MockWebRTCConnectionManager: WebRTCConnectionManaging {
    enum Error: Swift.Error {
        case connectionFailed
        case publishFailed
    }

    var onDisconnected: (() async -> Void)?
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?

    var room: Room?

    var inputTrack: LocalAudioTrack?
    var agentAudioTrack: RemoteAudioTrack?
    var isMicrophoneMuted = true

    var errorHandler: ((Swift.Error?) -> Void)?

    var shouldFailConnection = false
    var connectionError: Swift.Error = Error.connectionFailed
    var publishError: Swift.Error?
    var microphoneError: Swift.Error?

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectionDetails: TokenService.ConnectionDetails?
    private(set) var lastNetworkConfiguration: LiveKitNetworkConfiguration = .default
    private(set) var lastWaitTimeout: TimeInterval = 0
    private(set) var publishedPayloads: [Data] = []

    private var waitContinuation: CheckedContinuation<AgentReadyWaitResult, Never>?
    private var pendingWaitResult: AgentReadyWaitResult?

    func connect(
        details: TokenService.ConnectionDetails,
        enableMic _: Bool,
        throwOnMicrophoneFailure _: Bool,
        networkConfiguration: LiveKitNetworkConfiguration
    ) async throws {
        connectCallCount += 1
        lastConnectionDetails = details
        lastNetworkConfiguration = networkConfiguration

        if shouldFailConnection {
            errorHandler?(connectionError)
            throw connectionError
        }

        room = Room()
    }

    func disconnect() async {
        disconnectCallCount += 1
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil
        onRemoteSpeakingChanged = nil
        room = nil
    }

    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult {
        lastWaitTimeout = timeout
        if let pending = pendingWaitResult {
            pendingWaitResult = nil
            return pending
        }

        return await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func send(data: Data) async throws {
        guard room != nil else {
            throw ConnectionManagerError.notConnected
        }
        if let publishError {
            errorHandler?(publishError)
            throw publishError
        }
        publishedPayloads.append(data)
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard room != nil else {
            throw WebRTCConnectionManagerError.roomUnavailable
        }
        if let microphoneError {
            errorHandler?(microphoneError)
            throw microphoneError
        }
        isMicrophoneMuted = muted
    }

    // MARK: - Helpers

    func receive(data: Data) {
        handleIncomingData(data, logger: SDKLogger(logLevel: .error))
    }

    func succeedAgentReady(elapsed: TimeInterval = 0.1, viaGraceTimeout: Bool = false) {
        let detail = AgentReadyDetail(elapsed: elapsed, viaGraceTimeout: viaGraceTimeout)
        resumeWait(with: .success(detail))
    }

    func timeoutAgentReady(elapsed: TimeInterval = 0.1) {
        resumeWait(with: .timedOut(elapsed: elapsed))
    }

    private func resumeWait(with result: AgentReadyWaitResult) {
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume(returning: result)
        } else {
            pendingWaitResult = result
        }
    }
}
