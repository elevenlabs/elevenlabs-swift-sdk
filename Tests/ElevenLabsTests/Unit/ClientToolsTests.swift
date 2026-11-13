@testable import ElevenLabs
import Foundation
import XCTest

final class ClientToolsTests: XCTestCase {
    private struct Shipment: Encodable {
        let shippedAt: Date
    }

    func testJSONReplyEncodesDatesInISO8601() throws {
        let reply = try ClientToolReply.json(Shipment(shippedAt: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(reply, .result(#"{"shippedAt":"1970-01-01T00:00:00Z"}"#))
    }

    func testEncodableToolResultEncodesDatesInISO8601() throws {
        let event = try ClientToolResultEvent(
            toolCallId: "call_1",
            result: Shipment(shippedAt: Date(timeIntervalSince1970: 0))
        )

        XCTAssertEqual(event.result, #"{"shippedAt":"1970-01-01T00:00:00Z"}"#)
    }

    func testClientToolErrorDescribesItselfWithItsMessage() {
        let error: Error = ClientToolError("No such order.", errorType: .externalServer)

        XCTAssertEqual(error.localizedDescription, "No such order.")
    }
}
