@testable import ElevenLabs
import Foundation
import XCTest

final class ClientToolsTests: XCTestCase {
    private struct Shipment: Encodable {
        let shippedAt: Date
    }

    func testJSONResultsEncodeDatesInISO8601() throws {
        let shipment = Shipment(shippedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let json = #"{"shippedAt":"2023-11-14T22:13:20Z"}"#

        XCTAssertEqual(try ClientToolReply.result(json: shipment), .result(json))
        XCTAssertEqual(try ClientToolResultEvent(toolCallId: "call_1", result: shipment).result, json)
    }
}
