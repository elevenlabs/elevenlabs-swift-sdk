@testable import ElevenLabs
import Foundation
import XCTest

final class WebSocketConnectionManagerTests: XCTestCase {
    func testServerCloseCodeIsReported() {
        for closeCode in [URLSessionWebSocketTask.CloseCode.normalClosure, .goingAway, .policyViolation, .internalServerError] {
            let details = WebSocketConnectionManager.disconnectionDetails(closeCode: closeCode)
            XCTAssertEqual(details, DisconnectionDetails(reason: .remoteDisconnected, closeCode: closeCode.rawValue))
        }
    }

    func testSocketFailureWithoutCloseFrameHasNoCloseCode() {
        let details = WebSocketConnectionManager.disconnectionDetails(closeCode: .invalid)
        XCTAssertEqual(details, DisconnectionDetails(reason: .remoteDisconnected))
    }
}
