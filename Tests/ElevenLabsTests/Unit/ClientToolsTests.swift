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
