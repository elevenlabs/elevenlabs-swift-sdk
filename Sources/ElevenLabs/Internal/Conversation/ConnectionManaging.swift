import Foundation
import LiveKit

enum ConnectionManagerError: Error {
    case notConnected
}

protocol ConnectionManaging: AnyObject {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)? { get set }
    var onDisconnected: (() async -> Void)? { get set }
    var errorHandler: ((Swift.Error?) -> Void)? { get set }

    func disconnect() async
    func send(data: Data) async throws
}

protocol WebSocketConnectionManaging: ConnectionManaging {
    func connect(auth: ElevenLabsConfiguration, options: ConversationOptions) async throws -> StartupResult
}

protocol WebRTCConnectionManaging: ConnectionManaging {
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)? { get set }
    var inputTrack: LocalAudioTrack? { get }
    var agentAudioTrack: RemoteAudioTrack? { get }
    var isMicrophoneMuted: Bool { get }

    @MainActor
    func connect(
        auth: ElevenLabsConfiguration,
        options: ConversationOptions,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> StartupResult

    func setMicrophoneMuted(_ muted: Bool) async throws
}

extension ConnectionManaging {
    func handleIncomingData(_ data: Data, logger: any Logging) {
        do {
            if let event = try EventParser.parseIncomingEvent(from: data) {
                onEventReceived?(event)
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
}
