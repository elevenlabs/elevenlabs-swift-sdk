@testable import ElevenLabs
import Foundation
import LiveKit
import XCTest

@MainActor
final class ElevenLabsBusinessLogicTests: XCTestCase {
    private var conversation: Conversation!
    private var mockConnectionManager: MockConnectionManager!
    private var dependencyProvider: TestDependencyProvider!

    override func setUp() async throws {
        mockConnectionManager = MockConnectionManager()
        dependencyProvider = TestDependencyProvider(
            tokenService: MockTokenService(),
            connectionManager: mockConnectionManager
        )
        conversation = Conversation(dependencyProvider: dependencyProvider)
    }

    override func tearDown() async throws {
        conversation = nil
        mockConnectionManager = nil
        dependencyProvider = nil
    }

    // MARK: - Tool Call Tests

    func testToolCallLifecycle() async throws {
        // 1. Receive a tool call
        let toolCall = ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_123",
            parametersData: try JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1
        )
        
        await conversation._testing_handleIncomingEvent(.clientToolCall(toolCall))
        
        XCTAssertEqual(conversation.pendingToolCalls.count, 1)
        XCTAssertEqual(conversation.pendingToolCalls.first?.toolCallId, "call_123")
        
        // 2. Set up active state to allow sending result
        mockConnectionManager.room = Room()
        conversation._testing_setState(.active(CallInfo(agentId: "test")))
        
        // 3. Send result
        try await conversation.sendToolResult(for: "call_123", result: "success")
        
        // 4. Verify tool is removed from pending list
        XCTAssertTrue(conversation.pendingToolCalls.isEmpty)
        
        // 5. Verify result was published
        XCTAssertEqual(mockConnectionManager.publishedPayloads.count, 1)
        let lastPayload = mockConnectionManager.publishedPayloads.last ?? Data()
        let lastPayloadString = String(data: lastPayload, encoding: .utf8) ?? ""
        XCTAssertTrue(lastPayloadString.contains("call_123"))
        XCTAssertTrue(lastPayloadString.contains("success"))
    }

    // MARK: - Streaming Message Tests

    func testAgentStreamingMessages() async throws {
        // 1. Start streaming
        let startEvent = AgentChatResponsePartEvent(text: "Hello", type: .start)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(startEvent))
        
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello")
        XCTAssertEqual(conversation.messages.first?.role, .agent)
        
        // 2. Delta update
        let deltaEvent = AgentChatResponsePartEvent(text: " world", type: .delta)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(deltaEvent))
        
        XCTAssertEqual(conversation.messages.count, 1, "Should still have only 1 message, just updated")
        XCTAssertEqual(conversation.messages.first?.content, "Hello world")
        
        // 3. Stop streaming
        let stopEvent = AgentChatResponsePartEvent(text: "!", type: .stop)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(stopEvent))
        
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello world!")
    }

    // MARK: - End Call Logic

    func testAutomaticEndCallHandling() async throws {
        mockConnectionManager.room = Room()
        conversation._testing_setState(.active(CallInfo(agentId: "test")))
        
        let toolResponse = AgentToolResponseEvent(
            toolName: "end_call",
            toolCallId: "id",
            toolType: "action",
            isError: false,
            eventId: 1
        )
        
        await conversation._testing_handleIncomingEvent(.agentToolResponse(toolResponse))
        
        // Verify conversation ended automatically
        XCTAssertEqual(conversation.state, .ended(reason: .userEnded)) // endConversation() sets userEnded by default currently
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
        mockConnectionManager.succeedAgentReady()
        try await startTask.value
        
        XCTAssertEqual(conversation.state, .active(CallInfo(agentId: "new-agent")))
    }

    // MARK: - Audio Alignment

    func testAudioAlignmentUpdatesProperty() async throws {
        let alignment = AudioAlignment(
            chars: ["H", "e", "l", "l", "o"],
            charStartTimesMs: [0, 100, 200, 300, 400],
            charDurationsMs: [100, 100, 100, 100, 100]
        )
        let audioEvent = AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment)
        
        await conversation._testing_handleIncomingEvent(.audio(audioEvent))
        
        XCTAssertEqual(conversation.latestAudioAlignment?.chars, ["H", "e", "l", "l", "o"])
    }
}
