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

    func testServerCloseReasonIsReported() {
        let details = WebSocketConnectionManager.disconnectionDetails(
            closeCode: .policyViolation,
            closeReason: Data("Max duration exceeded".utf8)
        )
        XCTAssertEqual(details.closeReason, "Max duration exceeded")
    }

    func testEmptyServerCloseReasonIsNil() {
        XCTAssertNil(WebSocketConnectionManager.disconnectionDetails(closeCode: .normalClosure, closeReason: Data()).closeReason)
        XCTAssertNil(WebSocketConnectionManager.disconnectionDetails(closeCode: .normalClosure, closeReason: nil).closeReason)
    }
}
