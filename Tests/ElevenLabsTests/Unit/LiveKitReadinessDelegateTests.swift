@testable import ElevenLabs
import LiveKit
import XCTest

/// `RoomDelegate` methods are `@objc optional`, so a wrong signature compiles but
/// is never called. These references only type-check against genuine requirements.
@MainActor
final class LiveKitReadinessDelegateTests: XCTestCase {
    private func makeDelegate() -> RoomDelegate {
        LiveKitReadinessDelegate(logger: SDKLogger(logLevel: .warning))
    }

    func testImplementsGenuineRoomDelegateMethods() {
        let delegate = makeDelegate()

        let onConnect: ((Room) -> Void)? = delegate.roomDidConnect
        let onParticipantConnect: ((Room, RemoteParticipant) -> Void)? = delegate.room(_:participantDidConnect:)

        XCTAssertNotNil(onConnect, "roomDidConnect must be a real RoomDelegate requirement")
        XCTAssertNotNil(onParticipantConnect, "participantDidConnect must be a real RoomDelegate requirement")
    }
}
