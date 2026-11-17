@testable import ElevenLabs
import LiveKit
import XCTest

/// Verifies delegate callbacks implement correct `RoomDelegate` methods
final class LiveKitRoomEventDelegateTests: XCTestCase {
    private func makeDelegate(
        onData: @escaping @Sendable (Data) -> Void = { _ in },
        onRemoteSpeaking: @escaping @Sendable (Bool) -> Void = { _ in },
        onRemoteDisconnect: @escaping @Sendable (EndReason) async -> Void = { _ in },
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

    func testForwardsRoomDisconnectWithItsReason() async {
        let got = expectation(description: "disconnect")
        let delegate = makeDelegate(onRemoteDisconnect: { reason in
            if case .error = reason {} else { XCTFail("Expected .error, got \(reason)") }
            got.fulfill()
        })

        delegate.room?(Room(), didDisconnectWithError: LiveKitError(.serverShutdown))

        await fulfillment(of: [got], timeout: 1.0)
    }

    func testReportsOnlyTheFirstEnd() async throws {
        let got = expectation(description: "first end")
        let delegate = makeDelegate(onRemoteDisconnect: { reason in
            XCTAssertEqual(reason.details?.roomDisconnectReason, .roomDeleted)
            got.fulfill()
        })

        delegate.room?(Room(), didDisconnectWithError: LiveKitError(.roomDeleted))
        delegate.room?(Room(), didDisconnectWithError: LiveKitError(.serverShutdown))

        await fulfillment(of: [got], timeout: 1.0)
        // A second report would over-fulfill `got`, which fails the test.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testConnectionStateChangeIsNotReportedAsTheEnd() async {
        let notCalled = expectation(description: "disconnect")
        notCalled.isInverted = true
        let delegate = makeDelegate(onRemoteDisconnect: { _ in notCalled.fulfill() })

        delegate.room?(Room(), didUpdateConnectionState: .disconnected, from: .connected)

        await fulfillment(of: [notCalled], timeout: 0.1)
    }

    func testServerClosingTheRoomIsTheAgentEnding() {
        let deliberate: [(LiveKitErrorType, EndReason.RoomDisconnectReason)] = [
            (.roomDeleted, .roomDeleted), (.participantRemoved, .participantRemoved), (.cancelled, .clientInitiated)
        ]
        for (type, serverReason) in deliberate {
            let reason = LiveKitRoomEventDelegate.endReason(for: LiveKitError(type))
            guard case let .agentEnded(details) = reason else { return XCTFail("Expected .agentEnded, got \(reason)") }
            XCTAssertEqual(details.roomDisconnectReason, serverReason)
        }
    }

    func testServerEndingTheRoomWithAFailureIsAnErrorWithTheServerReason() {
        let failures: [(LiveKitErrorType, EndReason.RoomDisconnectReason)] = [
            (.serverShutdown, .serverShutdown), (.duplicateIdentity, .duplicateIdentity),
            (.stateMismatch, .stateMismatch), (.joinFailure, .joinFailure), (.unknown, .unknown)
        ]
        for (type, serverReason) in failures {
            let reason = LiveKitRoomEventDelegate.endReason(for: LiveKitError(type))
            guard case let .error(details) = reason else { return XCTFail("Expected .error, got \(reason)") }
            XCTAssertEqual(details.roomDisconnectReason, serverReason)
            XCTAssertEqual(details.message, "LiveKit room disconnected: \(type)")
        }
    }

    func testConnectionFailureIsAnErrorWithoutAServerReason() {
        for error in [LiveKitError(.network), LiveKitError(.serverPingTimedOut), nil] {
            let reason = LiveKitRoomEventDelegate.endReason(for: error)
            guard case let .error(details) = reason else { return XCTFail("Expected .error, got \(reason)") }
            XCTAssertNil(details.roomDisconnectReason)
        }
    }

    func testAgentLeavingAConnectedRoomEndsTheConversation() {
        XCTAssertTrue(LiveKitRoomEventDelegate.leaveEndsConversation(
            isAgent: true, isStillListed: false, othersRemain: false, roomState: .connected
        ))
        XCTAssertTrue(LiveKitRoomEventDelegate.leaveEndsConversation(
            isAgent: false, isStillListed: false, othersRemain: false, roomState: .connected
        ))
        XCTAssertFalse(LiveKitRoomEventDelegate.leaveEndsConversation(
            isAgent: false, isStillListed: false, othersRemain: true, roomState: .connected
        ))
    }

    func testRoomTeardownIsNotReportedAsTheAgentLeaving() {
        XCTAssertFalse(
            LiveKitRoomEventDelegate.leaveEndsConversation(
                isAgent: true, isStillListed: true, othersRemain: true, roomState: .connected
            ),
            "LiveKit reports participants it still lists while it tears the room down."
        )
        XCTAssertFalse(
            LiveKitRoomEventDelegate.leaveEndsConversation(
                isAgent: true, isStillListed: false, othersRemain: false, roomState: .reconnecting
            ),
            "A full reconnect drops the agent; that isn't the agent ending the conversation."
        )
    }
}
