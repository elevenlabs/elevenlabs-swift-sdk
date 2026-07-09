import Combine
@testable import ElevenLabs
import Foundation
import LiveKit
import XCTest

@MainActor
final class ElevenLabsBusinessLogicTests: XCTestCase {
    private var conversation: Conversation!
    private var mockWebRTCConnectionManager: MockWebRTCConnectionManager!
    private var dependencyProvider: TestDependencyProvider!

    override func setUp() async throws {
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        dependencyProvider = TestDependencyProvider(
            webRTCConnectionManager: mockWebRTCConnectionManager
        )
        conversation = Conversation(dependencyProvider: dependencyProvider)
    }

    override func tearDown() async throws {
        conversation = nil
        mockWebRTCConnectionManager = nil
        dependencyProvider = nil
    }

    // MARK: - Tool Call Tests

    func testToolCallLifecycle() async throws {
        try await conversation.startConversation(auth: .publicAgent(id: "test"))

        // 1. Receive a tool call
        let toolCall = try ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_123",
            parametersData: JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1,
            expectsResponse: false
        )
        mockWebRTCConnectionManager.deliver(.clientToolCall(toolCall))
        await waitForPublished(conversation.$pendingToolCalls) { $0.contains { $0.toolCallId == "call_123" } }

        XCTAssertEqual(conversation.pendingToolCalls.count, 1)
        XCTAssertEqual(conversation.pendingToolCalls.first?.toolCallId, "call_123")

        // 2. Send result
        let payloadCountBeforeResult = mockWebRTCConnectionManager.publishedPayloads.count
        try await conversation.sendToolResult(for: "call_123", result: "success")

        // 3. Verify tool is removed from pending list
        XCTAssertTrue(conversation.pendingToolCalls.isEmpty)

        // 4. Verify result was published
        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, payloadCountBeforeResult + 1)
        let lastPayload = mockWebRTCConnectionManager.publishedPayloads.last ?? Data()
        let lastPayloadString = String(data: lastPayload, encoding: .utf8) ?? ""
        XCTAssertTrue(lastPayloadString.contains("call_123"))
        XCTAssertTrue(lastPayloadString.contains("success"))
    }

    func testSendToolResultEncodesEncodableResult() async throws {
        struct Weather: Encodable {
            let temperature: Int
            let condition: String
        }

        try await conversation.startConversation(auth: .publicAgent(id: "test"))

        try await conversation.sendToolResult(
            for: "call_42",
            result: Weather(temperature: 25, condition: "Sunny")
        )

        let payload = try XCTUnwrap(mockWebRTCConnectionManager.publishedPayloads.last)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "client_tool_result")
        // The Encodable value is JSON-encoded into the `result` string.
        let resultString = try XCTUnwrap(envelope["result"] as? String)
        let parsed = try JSONSerialization.jsonObject(with: XCTUnwrap(resultString.data(using: .utf8))) as? [String: Any]
        XCTAssertEqual(parsed?["temperature"] as? Int, 25)
        XCTAssertEqual(parsed?["condition"] as? String, "Sunny")
    }

    // MARK: - Streaming Message Tests

    func testAgentStreamingMessages() async throws {
        try await conversation.startConversation(auth: .publicAgent(id: "test"))

        // 1. Start streaming
        mockWebRTCConnectionManager.deliver(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 1)
        ))
        await waitForPublished(conversation.$messages) { $0.first?.content == "Hello" }

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello")
        XCTAssertEqual(conversation.messages.first?.role, .agent)

        // 2. Delta update
        mockWebRTCConnectionManager.deliver(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: " world", type: .delta, eventId: 1)
        ))
        await waitForPublished(conversation.$messages) { $0.first?.content == "Hello world" }

        XCTAssertEqual(conversation.messages.count, 1, "Should still have only 1 message, just updated")
        XCTAssertEqual(conversation.messages.first?.content, "Hello world")

        // 3. Stop streaming
        mockWebRTCConnectionManager.deliver(.agentChatResponsePart(
            AgentChatResponsePartEvent(text: "!", type: .stop, eventId: 1)
        ))
        await waitForPublished(conversation.$messages) { $0.first?.content == "Hello world!" }

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello world!")
    }

    // MARK: - End Call Logic

    func testAutomaticEndCallHandling() async throws {
        try await conversation.startConversation(auth: .publicAgent(id: "test"))

        mockWebRTCConnectionManager.deliver(.agentToolResponse(AgentToolResponseEvent(
            toolName: "end_call", toolCallId: "id", toolType: "action", isError: false, eventId: 1
        )))
        await waitForPublished(conversation.$state) { $0 == .ended(reason: .userEnded) }

        XCTAssertEqual(conversation.state, .ended(reason: .userEnded))
    }

    // MARK: - Audio Alignment

    func testAudioAlignmentUpdatesProperty() async throws {
        try await conversation.startConversation(auth: .publicAgent(id: "test"))

        let alignment = AudioAlignment(
            chars: ["H", "e", "l", "l", "o"],
            charStartTimesMs: [0, 100, 200, 300, 400],
            charDurationsMs: [100, 100, 100, 100, 100]
        )
        mockWebRTCConnectionManager.deliver(.audio(AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment)))
        await waitForPublished(conversation.$latestAudioAlignment) { $0 != nil }

        XCTAssertEqual(conversation.latestAudioAlignment?.chars, ["H", "e", "l", "l", "o"])
    }

    func testEndConversationClearsLatestAudioState() async throws {
        try await conversation.startConversation(auth: .publicAgent(id: "test"))

        let alignment = AudioAlignment(chars: ["H"], charStartTimesMs: [0], charDurationsMs: [100])
        mockWebRTCConnectionManager.deliver(.audio(AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment)))
        await waitForPublished(conversation.$latestAudioAlignment) { $0 != nil }

        XCTAssertNotNil(conversation.latestAudioEvent)
        XCTAssertNotNil(conversation.latestAudioAlignment)

        await conversation.endConversation()

        XCTAssertNil(conversation.latestAudioEvent)
        XCTAssertNil(conversation.latestAudioAlignment)
    }
}
