@testable import ElevenLabs
import LiveKit
import XCTest

/// Verifies delegate callbacks implement correct `RoomDelegate` methods
final class LiveKitRoomEventDelegateTests: XCTestCase {
    private func makeDelegate(
        onData: @escaping @Sendable (Data) -> Void = { _ in },
        onRemoteSpeaking: @escaping @Sendable (Bool) -> Void = { _ in },
        onRemoteDisconnect: @escaping @Sendable () async -> Void = {},
        onTracksChanged: @escaping @Sendable () -> Void = {}
    ) -> RoomDelegate {
        LiveKitRoomEventDelegate(
            onData: onData,
            onRemoteSpeaking: onRemoteSpeaking,
            onRemoteDisconnect: onRemoteDisconnect,
            onTracksChanged: onTracksChanged
        )
    }

    func testForwardsReceivedData() async {
        let got = expectation(description: "data")
        let payload = Data([0x01, 0x02, 0x03])
        let delegate = makeDelegate(onData: {
            XCTAssertEqual($0, payload)
            got.fulfill()
        })

        delegate.room?(Room(), participant: nil, didReceiveData: payload, forTopic: "topic", encryptionType: .none)

        await fulfillment(of: [got], timeout: 1.0)
    }

    func testForwardsSpeaking() async {
        let got = expectation(description: "speaking")
        let delegate = makeDelegate(onRemoteSpeaking: {
            XCTAssertEqual($0, false, "No remote speakers must forward not-speaking.")
            got.fulfill()
        })

        delegate.room?(Room(), didUpdateSpeakingParticipants: [])

        await fulfillment(of: [got], timeout: 1.0)
    }

    func testForwardsDisconnectOnConnectionLoss() async {
        let got = expectation(description: "disconnect")
        let delegate = makeDelegate(onRemoteDisconnect: { got.fulfill() })

        delegate.room?(Room(), didUpdateConnectionState: .disconnected, from: .connected)

        await fulfillment(of: [got], timeout: 1.0)
    }

    func testIgnoresNonDisconnectedConnectionState() async {
        nonisolated(unsafe) var called = false
        let delegate = makeDelegate(onRemoteDisconnect: { called = true })

        delegate.room?(Room(), didUpdateConnectionState: .connected, from: .connecting)
        await Task { @MainActor in }.value

        XCTAssertFalse(called)
    }
}
