@testable import ElevenLabs
import Foundation
import XCTest

final class WebSocketStartupErrorTests: XCTestCase {
    private let socketError = URLError(.badServerResponse)

    func testRejectedHandshakeIsRefusedCredentials() {
        for status in [401, 403, 404] {
            XCTAssertEqual(
                startupError(httpStatus: status),
                .authenticationFailed("The server rejected the conversation with HTTP \(status)")
            )
        }
    }

    func testBusyOrFailingServerIsRetryable() {
        for status in [429, 500, 503] {
            XCTAssertEqual(
                startupError(httpStatus: status),
                .connectionFailed(.initializationFailed, "The server rejected the conversation with HTTP \(status)")
            )
        }
    }

    func testServerClosingTheSocketExplainsWhy() {
        XCTAssertEqual(
            startupError(httpStatus: 101, closeCode: 3000, closeReason: "Agent agent_x not found"),
            .authenticationFailed("The server closed the conversation (3000): Agent agent_x not found")
        )
        XCTAssertEqual(
            startupError(httpStatus: 101, closeCode: 1011, closeReason: nil),
            .connectionFailed(.initializationFailed, "The server closed the conversation (1011): no reason given")
        )
    }

    func testNetworkFailureKeepsTheUnderlyingMessage() {
        for closeCode in [0, 1005, 1006] {
            XCTAssertEqual(
                startupError(httpStatus: nil, closeCode: closeCode),
                .connectionFailed(.initializationFailed, socketError.localizedDescription)
            )
        }
    }

    private func startupError(httpStatus: Int?, closeCode: Int = 0, closeReason: String? = nil) -> ConversationError {
        WebSocketConnectionManager.startupError(
            for: socketError, httpStatus: httpStatus, closeCode: closeCode, closeReason: closeReason
        )
    }
}
