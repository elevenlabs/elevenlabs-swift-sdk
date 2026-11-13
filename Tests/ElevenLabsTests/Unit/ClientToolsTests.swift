@testable import ElevenLabs
import Foundation
import XCTest

final class ClientToolsTests: XCTestCase {
    private struct Shipment: Encodable {
        let shippedAt: Date
    }

    func testJSONResultsEncodeDatesInISO8601() throws {
        let shipment = Shipment(shippedAt: Date(timeIntervalSince1970: 0.123))
        let json = #"{"shippedAt":"1970-01-01T00:00:00.123Z"}"#

        XCTAssertEqual(try ClientToolReply.json(shipment), .result(json))
        XCTAssertEqual(try ClientToolResultEvent(toolCallId: "call_1", result: shipment).result, json)
    }

    // MARK: - Handler from a map

    @MainActor
    func testMapHandlerRunsTheToolWithTheCallsName() async throws {
        let handler = ClientTools.handler([
            "get_order": { _ in .result("Shipped") },
            "cancel_order": { _ in .pending }
        ])

        let order = try await handler(.fixture(toolName: "get_order"))
        let cancel = try await handler(.fixture(toolName: "cancel_order"))

        XCTAssertEqual(order, .result("Shipped"))
        XCTAssertEqual(cancel, .pending)
    }

    @MainActor
    func testMapHandlerFailsACallForAnUnknownTool() async {
        let handler = ClientTools.handler(["get_order": { _ in .result("Shipped") }])

        do {
            _ = try await handler(.fixture(toolName: "open_settings"))
            XCTFail("Expected an error for a tool that isn't in the map")
        } catch {
            XCTAssertEqual(
                error as? ClientToolError,
                ClientToolError("No client tool named open_settings is registered in this app.")
            )
        }
    }
}
