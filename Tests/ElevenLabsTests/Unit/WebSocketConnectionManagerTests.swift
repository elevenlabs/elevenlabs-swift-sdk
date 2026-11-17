@testable import ElevenLabs
import Foundation
import XCTest

final class WebSocketConnectionManagerTests: XCTestCase {
    private let receiveError = URLError(.networkConnectionLost)

    func testNormalCloseIsTheAgentEnding() {
        let reason = WebSocketConnectionManager.endReason(closeCode: .normalClosure, receiveError: receiveError)
        XCTAssertEqual(reason, .agentEnded())
    }

    func testOtherCloseCodesAreErrors() {
        for closeCode in [URLSessionWebSocketTask.CloseCode.goingAway, .policyViolation, .internalServerError] {
            let reason = WebSocketConnectionManager.endReason(closeCode: closeCode, receiveError: receiveError)
            XCTAssertEqual(
                reason,
                .error(EndReason.Details(message: "The connection was closed by the server.")),
                "\(closeCode.rawValue)"
            )
        }
    }

    func testSocketFailureWithoutCloseFrameIsAnError() {
        let reason = WebSocketConnectionManager.endReason(closeCode: .invalid, receiveError: receiveError)
        XCTAssertEqual(reason, .error(EndReason.Details(message: receiveError.localizedDescription)))
    }
}
