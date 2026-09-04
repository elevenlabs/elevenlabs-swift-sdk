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
        auth: ConversationAuth.TextOnly,
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

        let resolved: (url: URL, agentId: String)
        do {
            resolved = try await WebSocketConnectionManager.websocketUrl(
                for: auth,
                endpoints: config.endpoints,
                environment: config.environment
            )
            lastConnectedURL = resolved.url
        } catch {
            metrics.total = Date().timeIntervalSince(startTime)
            throw error as? ConversationError ?? .authenticationFailed(error)
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
            callInfo: CallInfo(agentId: resolved.agentId, conversationId: metadata.conversationId),
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

    @MainActor
    func receive(data: Data) async {
        guard let initiationMetadataWaiter else {
            preconditionFailure("Cannot receive data before connecting")
        }
        await Self.handleIncomingData(
            data,
            metadataWaiter: initiationMetadataWaiter,
            logger: SDKLogger(logLevel: .error),
            onEvent: { [weak self] event in
                self?.onEventReceived?(event)
            }
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
