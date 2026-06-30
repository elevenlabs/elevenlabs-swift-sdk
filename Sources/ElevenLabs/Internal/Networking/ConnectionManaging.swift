import Foundation
import LiveKit

enum ConnectionManagerError: Error {
    case notConnected
}

@MainActor
protocol ConnectionManaging: AnyObject {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)? { get set }
    var onDisconnected: (() async -> Void)? { get set }

    /// Raw, pre-dispatch tap on every incoming frame: the original transport
    /// bytes plus the parsed event (`nil` when the frame was unknown or
    /// otherwise unparseable). Wired to ``ConversationCallbacks/onMessage`` for
    /// logging/telemetry parity with the other ElevenLabs SDKs.
    var onRawMessage: (@Sendable (Data, IncomingEvent?) -> Void)? { get set }

    /// Reports startup-phase transitions as the manager progresses through its
    /// connection sequence (authorizing, connecting, waiting for the agent,
    /// sending the init handshake). Only ever invoked on the main actor during
    /// `connect`, so it is a plain (non-`Sendable`) closure. `Conversation`
    /// wires this to drive ``ConversationState/connecting(phase:)``.
    var onStartupPhaseChange: ((StartupPhase) -> Void)? { get set }

    /// Establish the transport connection and send the conversation-init
    /// handshake. Drives `onStartupPhaseChange` through the transport's own
    /// startup sequence and returns once the handshake has been sent.
    func connect(auth: ConversationAuth, config: ConversationConfig) async throws
    func disconnect() async
    func send(data: Data) async throws
}

@MainActor
protocol WebSocketConnectionManaging: ConnectionManaging {}

@MainActor
protocol WebRTCConnectionManaging: ConnectionManaging {
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)? { get set }
    /// Fired when an audio track is published/subscribed/removed, so callers can
    /// (re)attach renderers to `inputTrack` / `agentAudioTrack`.
    var onTracksChanged: (@Sendable () -> Void)? { get set }
    var inputTrack: LocalAudioTrack? { get }
    var agentAudioTrack: RemoteAudioTrack? { get }
    var isMicrophoneMuted: Bool { get }

    func setMicrophoneMuted(_ muted: Bool) async throws
}

extension ConnectionManaging {
    func handleIncomingData(_ data: Data, logger: any Logging) {
        let event: IncomingEvent?
        do {
            event = try EventParser.parseIncomingEvent(from: data)
        } catch let EventParseError.unknownEventType(type) {
            logger.debug("Ignoring unknown incoming event type", context: ["type": type])
            event = nil
        } catch {
            logger.error("Failed to parse incoming event", context: ["error": "\(error)"])
            logger.debug("Incoming raw data bytes", context: ["bytes": "\(data.count)"])
            event = nil
        }

        // Raw tap fires for every frame (including unknown/unparseable ones)
        // before the typed dispatch, so consumers see the unfiltered wire.
        onRawMessage?(data, event)

        if let event {
            onEventReceived?(event)
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
}
