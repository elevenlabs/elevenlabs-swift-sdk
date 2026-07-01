@testable import ElevenLabs
import Foundation

@MainActor
final class MockWebSocketConnectionManager: WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onRawMessage: (@Sendable (Data, IncomingEvent?) -> Void)?
    var onDisconnected: (() async -> Void)?
    var onStartupPhaseChange: ((StartupPhase) -> Void)?

    var connectError: Swift.Error?
    var sendError: Swift.Error?

    /// When true, `connect` synthesizes a `conversation_initiation_metadata`
    /// event on success so the production startup gate (which blocks until the
    /// metadata arrives) completes. Set to false to drive metadata manually.
    var autoDeliverMetadata = true
    var metadataConversationId = "mock-conversation-id"

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectedURL: URL?
    private(set) var sentPayloads: [Data] = []
    private(set) var isConnected = false

    func connect(auth: ConversationAuth, config: ConversationConfig) async throws {
        connectCallCount += 1

        do {
            lastConnectedURL = try WebSocketConnectionManager.url(
                for: auth,
                base: config.endpoints.textWebSocket,
                environment: config.environment
            )
        } catch {
            let convError = error as? ConversationError ?? .authenticationFailed(error.localizedDescription)
            throw ConversationStartupFailure.token(convError)
        }

        if let connectError {
            let convError = connectError as? ConversationError ?? .connectionFailed(connectError)
            throw ConversationStartupFailure.conversationInit(convError)
        }

        isConnected = true

        do {
            let initEvent = ConversationInitEvent(config: config)
            try await send(data: EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let convError = error as? ConversationError ?? .connectionFailed(error)
            throw ConversationStartupFailure.conversationInit(convError)
        }

        deliverMetadataIfNeeded()
    }

    func disconnect() async {
        disconnectCallCount += 1
        onEventReceived = nil
        onRawMessage = nil
        onDisconnected = nil
        onStartupPhaseChange = nil
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
        handleIncomingData(data, logger: SDKLogger(levelOverride: .error))
    }

    private func deliverMetadataIfNeeded() {
        guard autoDeliverMetadata else { return }
        onEventReceived?(.conversationMetadata(ConversationMetadataEvent(
            conversationId: metadataConversationId,
            agentOutputAudioFormat: "pcm_16000",
            userInputAudioFormat: "pcm_16000"
        )))
    }
}
