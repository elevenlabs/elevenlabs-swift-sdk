import Foundation
import LiveKit

@MainActor
protocol ConversationConnectionManagerDelegate: AnyObject {
    func connectionManager(
        _ manager: ConversationConnectionManager,
        didUpdateSpeakingState isSpeaking: Bool,
        for participant: Participant
    )
    func connectionManager(
        _ manager: ConversationConnectionManager,
        participantDidJoin participant: RemoteParticipant
    )
    func connectionManager(
        _ manager: ConversationConnectionManager,
        didReceiveData data: Data
    )
    func connectionManager(
        _ manager: ConversationConnectionManager,
        didUpdateConnectionState state: ConnectionState
    )
}

@MainActor
final class ConversationConnectionManager: NSObject, RoomDelegate, ParticipantDelegate {
    weak var delegate: ConversationConnectionManagerDelegate?

    let connectionManager: any ConnectionManaging

    var room: Room? {
        connectionManager.room
    }

    var onAgentDisconnected: (() -> Void)? {
        get { connectionManager.onAgentDisconnected }
        set { connectionManager.onAgentDisconnected = newValue }
    }

    init(connectionManager: any ConnectionManaging) {
        self.connectionManager = connectionManager
        super.init()
    }

    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        throwOnMicrophoneFailure: Bool = true,
        networkConfiguration: LiveKitNetworkConfiguration,
        graceTimeout: TimeInterval
    ) async throws {
        try await connectionManager.connect(
            details: details,
            enableMic: enableMic,
            throwOnMicrophoneFailure: throwOnMicrophoneFailure,
            networkConfiguration: networkConfiguration,
            graceTimeout: graceTimeout
        )

        if let room = connectionManager.room {
            room.add(delegate: self)
            for participant in room.remoteParticipants.values {
                participant.add(delegate: self)
            }
        }
    }

    func disconnect() async {
        await connectionManager.disconnect()
    }

    func waitForAgentReady(timeout: TimeInterval) async -> AgentReadyWaitResult {
        await connectionManager.waitForAgentReady(timeout: timeout)
    }

    func publish(data: Data, options: DataPublishOptions) async throws {
        try await connectionManager.publish(data: data, options: options)
    }

    // MARK: - RoomDelegate

    nonisolated func room(_: Room, participant: Participant, didUpdateIsSpeaking isSpeaking: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.connectionManager(self, didUpdateSpeakingState: isSpeaking, for: participant)
        }
    }

    nonisolated func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            participant.add(delegate: self)
            delegate?.connectionManager(self, participantDidJoin: participant)
        }
    }

    nonisolated func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from _: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.connectionManager(self, didUpdateConnectionState: connectionState)
        }
    }

    nonisolated func room(
        _: Room,
        participant _: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic _: String,
        encryptionType _: EncryptionType
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.connectionManager(self, didReceiveData: data)
        }
    }

    // MARK: - ParticipantDelegate

    nonisolated func participant(_ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.connectionManager(self, didUpdateSpeakingState: isSpeaking, for: participant)
        }
    }
}
