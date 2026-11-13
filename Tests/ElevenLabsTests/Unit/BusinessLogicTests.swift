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
        // Set up active state with room first
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.active(CallInfo(agentId: "test")))

        // 1. Receive a tool call
        let toolCall = try ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_123",
            parametersData: JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1,
            expectsResponse: false
        )

        await conversation._testing_handleIncomingEvent(.clientToolCall(toolCall))

        XCTAssertEqual(conversation.pendingToolCalls.count, 1)
        XCTAssertEqual(conversation.pendingToolCalls.first?.toolCallId, "call_123")

        // 2. Send result
        try await conversation.sendToolResult(for: "call_123", result: "success")

        // 3. Verify tool is removed from pending list
        XCTAssertTrue(conversation.pendingToolCalls.isEmpty)

        // 4. Verify result was published
        XCTAssertEqual(mockWebRTCConnectionManager.publishedPayloads.count, 1)
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
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.active(CallInfo(agentId: "test")))

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

    // MARK: - Registered Client Tool Tests

    private struct ToolFailure: LocalizedError {
        var errorDescription: String? {
            "Location unavailable"
        }
    }

    private func activeConversation(
        clientTools: [String: ClientToolHandler],
        onUnhandledClientToolCall: (@Sendable (ClientToolCallEvent) -> Void)? = nil
    ) -> Conversation {
        let conversation = Conversation(
            dependencyProvider: dependencyProvider,
            options: ConversationOptions(clientTools: clientTools, onUnhandledClientToolCall: onUnhandledClientToolCall)
        )
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.active(CallInfo(agentId: "test")))
        return conversation
    }

    private func clientToolCall(name: String, expectsResponse: Bool = true) throws -> ClientToolCallEvent {
        try ClientToolCallEvent(
            toolName: name,
            toolCallId: "call_\(name)",
            parametersData: JSONSerialization.data(withJSONObject: ["city": "Paris"]),
            eventId: 1,
            expectsResponse: expectsResponse
        )
    }

    private func lastPublishedEnvelope() throws -> [String: Any] {
        let payload = try XCTUnwrap(mockWebRTCConnectionManager.publishedPayloads.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    func testRegisteredClientToolRunsHandlerAndSendsResult() async throws {
        let conversation = activeConversation(clientTools: [
            "get_weather": { call in
                let city = try call.getParameters()["city"] as? String ?? "unknown"
                return "Sunny in \(city)"
            }
        ])

        try await conversation._testing_handleIncomingEvent(.clientToolCall(clientToolCall(name: "get_weather")))

        let envelope = try lastPublishedEnvelope()
        XCTAssertEqual(envelope["type"] as? String, "client_tool_result")
        XCTAssertEqual(envelope["tool_call_id"] as? String, "call_get_weather")
        XCTAssertEqual(envelope["result"] as? String, "Sunny in Paris")
        XCTAssertEqual(envelope["is_error"] as? Bool, false)
        XCTAssertTrue(conversation.pendingToolCalls.isEmpty)
    }

    func testRegisteredClientToolReturningNilSendsDefaultSuccess() async throws {
        let conversation = activeConversation(clientTools: ["open_screen": { _ in nil }])

        try await conversation._testing_handleIncomingEvent(.clientToolCall(clientToolCall(name: "open_screen")))

        let envelope = try lastPublishedEnvelope()
        XCTAssertEqual(envelope["result"] as? String, "Client tool execution successful.")
        XCTAssertEqual(envelope["is_error"] as? Bool, false)
    }

    func testRegisteredClientToolThatThrowsSendsErrorResult() async throws {
        let conversation = activeConversation(clientTools: ["get_location": { _ in throw ToolFailure() }])

        try await conversation._testing_handleIncomingEvent(.clientToolCall(clientToolCall(name: "get_location")))

        let envelope = try lastPublishedEnvelope()
        XCTAssertEqual(envelope["tool_call_id"] as? String, "call_get_location")
        XCTAssertEqual(envelope["result"] as? String, "Client tool execution failed: Location unavailable")
        XCTAssertEqual(envelope["is_error"] as? Bool, true)
    }

    func testRegisteredClientToolWithoutExpectedResponseSendsNothing() async throws {
        let ranToolCalls = ValueRecorder<String>()
        let conversation = activeConversation(clientTools: [
            "log_event": { call in
                await ranToolCalls.append(call.toolCallId)
                return "logged"
            }
        ])

        try await conversation._testing_handleIncomingEvent(
            .clientToolCall(clientToolCall(name: "log_event", expectsResponse: false))
        )

        let ran = await ranToolCalls.values()
        XCTAssertEqual(ran, ["call_log_event"])
        XCTAssertTrue(mockWebRTCConnectionManager.publishedPayloads.isEmpty)
    }

    func testClientToolWithoutHandlerStaysPendingForTheApp() async throws {
        let unhandledToolCalls = ValueRecorder<String>()
        let conversation = activeConversation(
            clientTools: ["get_weather": { _ in "Sunny" }],
            onUnhandledClientToolCall: { call in
                Task { await unhandledToolCalls.append(call.toolCallId) }
            }
        )

        try await conversation._testing_handleIncomingEvent(.clientToolCall(clientToolCall(name: "other_tool")))

        XCTAssertEqual(conversation.pendingToolCalls.map(\.toolCallId), ["call_other_tool"])
        let unhandled = await unhandledToolCalls.values(waitingFor: 1)
        XCTAssertEqual(unhandled, ["call_other_tool"])
        XCTAssertTrue(mockWebRTCConnectionManager.publishedPayloads.isEmpty)
    }

    // MARK: - Streaming Message Tests

    func testAgentStreamingMessages() async {
        // 1. Start streaming
        let startEvent = AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 1, responseId: "response-1")
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(startEvent))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello")
        XCTAssertEqual(conversation.messages.first?.role, .agent)

        // 2. Delta update
        let deltaEvent = AgentChatResponsePartEvent(text: " world", type: .delta, eventId: 1, responseId: "response-1")
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(deltaEvent))

        XCTAssertEqual(conversation.messages.count, 1, "Should still have only 1 message, just updated")
        XCTAssertEqual(conversation.messages.first?.content, "Hello world")

        // 3. Stop streaming
        let stopEvent = AgentChatResponsePartEvent(text: "!", type: .stop, eventId: 1, responseId: "response-1")
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(stopEvent))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello world!")
    }

    // MARK: - End Call Logic

    func testAutomaticEndCallHandling() async {
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setState(.active(CallInfo(agentId: "test")))

        let toolResponse = AgentToolResponseEvent(
            toolName: "end_call",
            toolCallId: "id",
            toolType: "action",
            isError: false,
            eventId: 1
        )

        await conversation._testing_handleIncomingEvent(.agentToolResponse(toolResponse))

        // Verify conversation is still active (endConversation guards state.isActive so won't change from idle)
        XCTAssertEqual(conversation.state, .active(CallInfo(agentId: "test")))
    }

    // MARK: - Concurrency & Responsiveness

    func testStateTransitionsImmediatelyToConnecting() async throws {
        // Simulate a previously ended conversation
        conversation._testing_setState(.ended(reason: .userEnded))

        // Start a new one
        let startTask = Task {
            try await conversation.startConversation(auth: .publicAgent(id: "new-agent"))
        }

        // Check state immediately
        await Task.yield()
        XCTAssertEqual(conversation.state, .connecting, "Should be connecting immediately, even if disconnect() is slow")

        // Complete the start
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

        XCTAssertEqual(conversation.state, .active(CallInfo(agentId: "new-agent")))
    }

    // MARK: - Audio Alignment

    func testAudioAlignmentUpdatesProperty() async {
        let alignment = AudioAlignment(
            chars: ["H", "e", "l", "l", "o"],
            charStartTimesMs: [0, 100, 200, 300, 400],
            charDurationsMs: [100, 100, 100, 100, 100]
        )
        let audioEvent = AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment)

        await conversation._testing_handleIncomingEvent(.audio(audioEvent))

        XCTAssertEqual(conversation.latestAudioAlignment?.chars, ["H", "e", "l", "l", "o"])
    }

    func testEndConversationClearsLatestAudioState() async {
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.active(CallInfo(agentId: "test")))

        let alignment = AudioAlignment(
            chars: ["H"],
            charStartTimesMs: [0],
            charDurationsMs: [100]
        )
        let audioEvent = AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment)

        await conversation._testing_handleIncomingEvent(.audio(audioEvent))
        XCTAssertNotNil(conversation.latestAudioEvent)
        XCTAssertNotNil(conversation.latestAudioAlignment)

        await conversation.endConversation()

        XCTAssertNil(conversation.latestAudioEvent)
        XCTAssertNil(conversation.latestAudioAlignment)
    }
}
