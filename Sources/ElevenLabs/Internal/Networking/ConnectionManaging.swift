import Foundation
import LiveKit

enum ConnectionManagerError: Error {
    case notConnected
}

@MainActor
public protocol ConnectionManaging: AnyObject {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)? { get set }
    var onDisconnected: (() async -> Void)? { get set }
    var errorHandler: ((Swift.Error?) -> Void)? { get set }

    func disconnect() async
    func send(data: Data) async throws
}

@MainActor
public protocol WebSocketConnectionManaging: ConnectionManaging {
    func connect(
        auth: ConversationAuth.TextOnly,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult
}

@MainActor
public protocol WebRTCConnectionManaging: ConnectionManaging {
    func connect(
        auth: ConversationAuth.Voice,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult

    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)? { get set }
    /// Fired when an audio track is published/subscribed/unpublished/unsubscribed.
    var onTracksChanged: (@Sendable () -> Void)? { get set }
    var isMicrophoneMuted: Bool { get }

    func setMicrophoneMuted(_ muted: Bool) async throws

    func setAgentMuted(_ muted: Bool)
}

@MainActor
protocol AudioTrackProviding {
    var inputTrack: (any AudioTrackProtocol)? { get }
    var agentAudioTrack: (any AudioTrackProtocol)? { get }
}

extension ConnectionManaging {
    /// Parses transport data off the main actor before delivering events on it.
    nonisolated static func handleIncomingData(
        _ data: Data,
        metadataWaiter: ConversationInitiationMetadataWaiter,
        logger: any Logging,
        onEvent: @escaping @MainActor @Sendable (IncomingEvent) -> Void
    ) async {
        do {
            if let event = try EventParser.parseIncomingEvent(from: data) {
                if case let .conversationMetadata(metadata) = event {
                    await metadataWaiter.observe(metadata)
                }
                await onEvent(event)
            }
        } catch let EventParseError.unknownEventType(type) {
            // Unrecognized event types are expected (newer server) — not errors.
            logger.debug("Ignoring unknown incoming event type", context: ["type": type])
        } catch {
            logger.error("Failed to parse incoming event", context: ["error": "\(error)"])
            logger.debug("Incoming raw data bytes", context: ["bytes": "\(data.count)"])
        }
    }

    func send(event: OutgoingEvent) async throws {
        let data = try EventSerializer.serializeOutgoingEvent(event)

        do {
            try await send(data: data)
        } catch ConnectionManagerError.notConnected {
            throw ConversationError.notConnected
        }
    }

    @MainActor
    func waitForInitiationMetadata(
        config: ConversationConfig,
        metrics: inout ConversationStartupMetrics,
        startTime: Date,
        metadataWaiter: ConversationInitiationMetadataWaiter,
        onStartupStateChange: (ConversationStartupState) -> Void
    ) async throws -> ConversationMetadataEvent {
        let timeout = config.startupConfiguration.initiationMetadataTimeout
        onStartupStateChange(.waitingForInitiationMetadata(timeout: timeout))

        let waitStart = Date()
        do {
            let metadata = try await metadataWaiter.wait()
            metrics.initiationMetadata = Date().timeIntervalSince(waitStart)
            metrics.total = Date().timeIntervalSince(startTime)
            return metadata
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            metrics.initiationMetadata = Date().timeIntervalSince(waitStart)
            metrics.total = Date().timeIntervalSince(startTime)
            throw ConversationStartupError(
                stage: .waitingForInitiationMetadata(timeout: timeout),
                metrics: metrics,
                underlyingError: error as? ConversationError ?? .connectionFailed(error)
            )
        }
    }
}
