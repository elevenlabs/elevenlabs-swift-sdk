@testable import ElevenLabs
import Foundation
import LiveKit

@MainActor
final class MockConnectionManager: ConnectionManaging {
    enum Error: Swift.Error {
        case connectionFailed
        case publishFailed
    }

    var onAgentReady: (() -> Void)?
    var onAgentDisconnected: (() -> Void)?

    var room: Room?
    var shouldObserveRoomConnection: Bool { false }
    var errorHandler: (Swift.Error?) -> Void = { _ in }

    var shouldFailConnection = false
    var connectionError: Swift.Error = Error.connectionFailed
    var publishError: Swift.Error?

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectionDetails: TokenService.ConnectionDetails?
    private(set) var lastGraceTimeout: TimeInterval = 0
    private(set) var lastNetworkConfiguration: LiveKitNetworkConfiguration = .default
    private(set) var publishedPayloads: [Data] = []

    private var waitContinuation: CheckedContinuation<AgentReadyWaitResult, Never>?
    private var pendingWaitResult: AgentReadyWaitResult?

    func connect(
        details: TokenService.ConnectionDetails,
        enableMic _: Bool,
        networkConfiguration: LiveKitNetworkConfiguration,
        graceTimeout: TimeInterval
    ) async throws {
        connectCallCount += 1
        lastConnectionDetails = details
        lastGraceTimeout = graceTimeout
        lastNetworkConfiguration = networkConfiguration

        if shouldFailConnection {
            errorHandler(connectionError)
            throw connectionError
        }

        room = Room()
    }

    func disconnect() async {
        disconnectCallCount += 1
        let hadRoom = room != nil
        room = nil
        if hadRoom {
            onAgentDisconnected?()
        }
    }

    func dataEventsStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func waitForAgentReady(timeout _: TimeInterval) async -> AgentReadyWaitResult {
        if let pending = pendingWaitResult {
            pendingWaitResult = nil
            return pending
        }

        return await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func publish(data: Data, options _: DataPublishOptions) async throws {
        if let publishError {
            errorHandler(publishError)
            throw publishError
        }
        publishedPayloads.append(data)
    }

    // MARK: - Helpers

    func succeedAgentReady(elapsed: TimeInterval = 0.1, viaGraceTimeout: Bool = false) {
        let detail = AgentReadyDetail(elapsed: elapsed, viaGraceTimeout: viaGraceTimeout)
        resumeWait(with: .success(detail))
        onAgentReady?()
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
