@testable import ElevenLabs
import Foundation
import XCTest

final class WebSocketConnectionManagerTests: XCTestCase {
    private let receiveError = URLError(.networkConnectionLost)

    func testNormalCloseIsTheAgentEnding() {
        let reason = WebSocketConnectionManager.endReason(closeCode: .normalClosure, receiveError: receiveError)
        XCTAssertEqual(reason, .agentEnded(EndReason.Details(closeCode: 1000)))
    }

    func testOtherCloseCodesAreErrorsWithTheCode() {
        for closeCode in [URLSessionWebSocketTask.CloseCode.goingAway, .policyViolation, .internalServerError] {
            let reason = WebSocketConnectionManager.endReason(closeCode: closeCode, receiveError: receiveError)
            guard case let .error(details) = reason else { return XCTFail("Expected .error, got \(reason)") }
            XCTAssertEqual(details.closeCode, closeCode.rawValue)
            XCTAssertEqual(details.message, "The connection was closed by the server.")
        }
    }

    func testSocketFailureWithoutCloseFrameIsAnErrorWithoutACode() {
        let reason = WebSocketConnectionManager.endReason(closeCode: .invalid, receiveError: receiveError)
        XCTAssertEqual(reason, .error(EndReason.Details(message: receiveError.localizedDescription)))
        XCTAssertNil(reason.details?.closeCode)
    }
}
