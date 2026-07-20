@testable import ElevenLabs
import Foundation

final class MockWebSocketConnectionManager: WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onDisconnected: (() async -> Void)?
    var errorHandler: ((Swift.Error?) -> Void)?
    private var initiationMetadataWaiter: ConversationInitiationMetadataWaiter?

    var connectError: Error?
    var sendError: Error?
    var autoDeliverInitiationMetadata = true
    var initiationMetadataConversationId = "test-conversation-id"

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectedURL: URL?
    private(set) var sentPayloads: [Data] = []
    private(set) var isConnected = false

    @MainActor
    func connect(
        auth: ConversationCredentials,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult {
        await initiationMetadataWaiter?.cancel()
        let waiter = ConversationInitiationMetadataWaiter(
            timeout: config.startupConfiguration.initiationMetadataTimeout
        )
        initiationMetadataWaiter = waiter
        connectCallCount += 1
        let startTime = Date()
        var metrics = ConversationStartupMetrics()

        do {
            lastConnectedURL = try WebSocketConnectionManager.url(for: auth)
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            let convError = error as? ConversationError ?? .authenticationFailed(error.localizedDescription)
            throw convError
        }

        if let connectError {
            errorHandler?(connectError)
            metrics.total = Date().timeIntervalSince(startTime)
            throw connectError as? ConversationError ?? ConversationError.connectionFailed(connectError)
        }

        isConnected = true

        onStartupStateChange(.sendingConversationInit)
        do {
            let initEvent = ConversationInitEvent(config: config)
            try await send(data: EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            throw error as? ConversationError ?? ConversationError.connectionFailed(error)
        }

        if autoDeliverInitiationMetadata {
            let metadata = makeInitiationMetadata()
            await waiter.observe(metadata)
            onEventReceived?(.conversationMetadata(metadata))
        }

        let metadata = try await waitForInitiationMetadata(
            config: config,
            metrics: &metrics,
            startTime: startTime,
            metadataWaiter: waiter,
            onStartupStateChange: onStartupStateChange
        )
        return ConversationStartResult(
            callInfo: CallInfo(agentId: auth.agentId, conversationId: metadata.conversationId),
            metrics: metrics
        )
    }

    func disconnect() async {
        disconnectCallCount += 1
        onEventReceived = nil
        onDisconnected = nil
        errorHandler = nil
        isConnected = false
        await initiationMetadataWaiter?.cancel()
        initiationMetadataWaiter = nil
    }

    func send(data: Data) async throws {
        guard isConnected else {
            throw ConnectionManagerError.notConnected
        }
        if let sendError {
            errorHandler?(sendError)
            throw sendError
        }
        sentPayloads.append(data)
    }

    func receive(data: Data) {
        guard let initiationMetadataWaiter else {
            preconditionFailure("Cannot receive data before connecting")
        }
        handleIncomingData(
            data,
            metadataWaiter: initiationMetadataWaiter,
            logger: SDKLogger(logLevel: .error)
        )
    }

    private func makeInitiationMetadata() -> ConversationMetadataEvent {
        ConversationMetadataEvent(
            conversationId: initiationMetadataConversationId,
            agentOutputAudioFormat: "pcm_16000",
            userInputAudioFormat: "pcm_16000"
        )
    }
}
