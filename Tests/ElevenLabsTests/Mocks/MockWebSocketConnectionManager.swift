@testable import ElevenLabs
import Foundation

final class MockWebSocketConnectionManager: WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onDisconnected: (() async -> Void)?

    var connectError: Error?
    var sendError: Error?

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectedURL: URL?
    private(set) var sentPayloads: [Data] = []
    private(set) var isConnected = false

    func connect(auth: ElevenLabsConfiguration, options: ConversationOptions) async throws -> StartupResult {
        connectCallCount += 1
        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        do {
            lastConnectedURL = try WebSocketConnectionManager.url(for: auth)
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            let convError = error as? ConversationError ?? .authenticationFailed(error.localizedDescription)
            throw StartupFailure.token(convError, metrics)
        }

        if let connectError {
            metrics.total = Date().timeIntervalSince(startTime)
            let convError = connectError as? ConversationError ?? .connectionFailed(connectError)
            throw StartupFailure.conversationInit(convError, metrics)
        }

        isConnected = true

        do {
            let initEvent = ConversationInitEvent(config: options.toConversationConfig())
            try await send(data: EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            let convError = error as? ConversationError ?? .connectionFailed(error)
            throw StartupFailure.conversationInit(convError, metrics)
        }

        metrics.conversationInitAttempts = 1
        metrics.total = Date().timeIntervalSince(startTime)
        return StartupResult(agentId: auth.agentId, metrics: metrics)
    }

    func disconnect() async {
        disconnectCallCount += 1
        onEventReceived = nil
        onDisconnected = nil
        isConnected = false
    }

    func send(data: Data) async throws {
        guard isConnected else {
            throw ConnectionManagerError.notConnected
        }
        if let sendError {
            throw sendError
        }
        sentPayloads.append(data)
    }

    func receive(data: Data) {
        handleIncomingData(data, logger: SDKLogger(logLevel: .error))
    }
}
