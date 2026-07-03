@testable import ElevenLabs
import LiveKit
import XCTest

/// Verifies delegate callbacks implement the `RoomDelegate` methods LiveKit actually calls.
final class LiveKitRoomEventDelegateTests: XCTestCase {
    private func makeDelegate(
        onData: @escaping @Sendable (Data) -> Void = { _ in },
        onRemoteSpeaking: @escaping @Sendable (Bool) -> Void = { _ in },
        onRemoteDisconnect: @escaping @Sendable () async -> Void = {}
    ) -> RoomDelegate {
        LiveKitRoomEventDelegate(
            onData: onData,
            onRemoteSpeaking: onRemoteSpeaking,
            onRemoteDisconnect: onRemoteDisconnect
        )
    }

    func testForwardsReceivedData() async {
        let received = ValueRecorder<Data>()
        let delegate = makeDelegate(onData: { value in Task { await received.append(value) } })
        let payload = Data([0x01, 0x02, 0x03])

        delegate.room?(Room(), participant: nil, didReceiveData: payload, forTopic: "topic", encryptionType: .none)

        let values = await received.values(waitingFor: 1)
        XCTAssertEqual(values, [payload])
    }

    func testForwardsSpeaking() async {
        let speaking = ValueRecorder<Bool>()
        let delegate = makeDelegate(onRemoteSpeaking: { value in Task { await speaking.append(value) } })

        delegate.room?(Room(), didUpdateSpeakingParticipants: [])

        let values = await speaking.values(waitingFor: 1)
        XCTAssertEqual(values, [false], "No remote speakers must forward not-speaking.")
    }

    func testForwardsDisconnectOnConnectionLoss() async {
        let disconnects = ValueRecorder<Bool>()
        let delegate = makeDelegate(onRemoteDisconnect: { await disconnects.append(true) })

        delegate.room?(Room(), didUpdateConnectionState: .disconnected, from: .connected)

        let values = await disconnects.values(waitingFor: 1)
        XCTAssertEqual(values, [true])
    }

    func testIgnoresNonDisconnectedConnectionState() async {
        let disconnects = ValueRecorder<Bool>()
        let delegate = makeDelegate(onRemoteDisconnect: { await disconnects.append(true) })

        delegate.room?(Room(), didUpdateConnectionState: .connected, from: .connecting)

        let values = await disconnects.values(waitingFor: 1, timeout: 0.2)
        XCTAssertTrue(values.isEmpty, "Only a disconnected state should signal disconnect.")
    }
}
