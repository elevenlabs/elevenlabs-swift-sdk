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

    func testClientToolCallIsAppendedBeforeCallbackFires() async throws {
        // Snapshot what a handler observes at the instant `onClientToolCall`
        // fires. The callback is `@Sendable`; it runs synchronously on the main
        // actor inside the handler, so `assumeIsolated` is safe here.
        final class OrderBox: @unchecked Sendable {
            weak var conversation: Conversation?
            var pendingCountAtCallback: Int?
        }
        let box = OrderBox()
        var callbacks = ConversationCallbacks()
        callbacks.onClientToolCall = { _ in
            MainActor.assumeIsolated {
                box.pendingCountAtCallback = box.conversation?.pendingToolCalls.count
            }
        }
        let conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: callbacks)
        box.conversation = conversation
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.connected)

        let toolCall = try ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_order",
            parametersData: JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1
        )
        await conversation._testing_handleIncomingEvent(.clientToolCall(toolCall))

        XCTAssertEqual(
            box.pendingCountAtCallback, 1,
            "onClientToolCall must fire after the call is appended to pendingToolCalls"
        )
        XCTAssertEqual(conversation.pendingToolCalls.first?.toolCallId, "call_order")
    }

    func testToolCallLifecycle() async throws {
        // Set up active state with room first
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setWebRTCConnectionManager(mockWebRTCConnectionManager)
        conversation._testing_setState(.connected)

        // 1. Receive a tool call
        let toolCall = try ClientToolCallEvent(
            toolName: "test_tool",
            toolCallId: "call_123",
            parametersData: JSONSerialization.data(withJSONObject: ["arg": "val"]),
            eventId: 1
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

    // MARK: - Reset

    func testResetClearsTerminalStateAndTranscript() async {
        // Seed a transcript, then land in a terminal failed state.
        let part = AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 1)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(part))
        XCTAssertEqual(conversation.messages.count, 1)

        conversation._testing_setState(.startupFailed(.token(.authenticationFailed("denied"))))

        conversation.reset()

        XCTAssertEqual(conversation.state, .idle)
        XCTAssertTrue(conversation.messages.isEmpty, "reset() must clear the preserved transcript")
        XCTAssertNil(conversation.conversationMetadata)
    }

    func testResetIsNoOpWhenIdle() {
        XCTAssertEqual(conversation.state, .idle)
        conversation.reset()
        XCTAssertEqual(conversation.state, .idle)
    }

    // MARK: - Streaming Message Tests

    func testAgentStreamingMessages() async {
        // 1. Start streaming
        let startEvent = AgentChatResponsePartEvent(text: "Hello", type: .start, eventId: 1)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(startEvent))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello")
        XCTAssertEqual(conversation.messages.first?.role, .agent)

        // 2. Delta update
        let deltaEvent = AgentChatResponsePartEvent(text: " world", type: .delta, eventId: 1)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(deltaEvent))

        XCTAssertEqual(conversation.messages.count, 1, "Should still have only 1 message, just updated")
        XCTAssertEqual(conversation.messages.first?.content, "Hello world")

        // 3. Stop streaming
        let stopEvent = AgentChatResponsePartEvent(text: "!", type: .stop, eventId: 1)
        await conversation._testing_handleIncomingEvent(.agentChatResponsePart(stopEvent))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "Hello world!")
    }

    // MARK: - End Call Logic

    func testAutomaticEndCallHandling() async {
        mockWebRTCConnectionManager.room = Room()
        conversation._testing_setState(.connected)

        let toolResponse = AgentToolResponseEvent(
            toolName: "end_call",
            toolCallId: "id",
            toolType: "action",
            isError: false,
            eventId: 1
        )

        await conversation._testing_handleIncomingEvent(.agentToolResponse(toolResponse))

        // Verify conversation remains connected (end_call handling does not force-end here)
        XCTAssertEqual(conversation.state, .connected)
    }

    // MARK: - Concurrency & Responsiveness

    func testStateTransitionsImmediatelyToConnecting() async throws {
        // A fresh (single-use) conversation starts in `.idle`.
        let startTask = Task {
            try await conversation.startConversation(auth: .publicAgent(id: "new-agent"))
        }

        // Check state immediately
        await Task.yield()
        XCTAssertTrue(conversation.state.isConnecting, "Should be connecting immediately, even if disconnect() is slow")

        // Complete the start
        mockWebRTCConnectionManager.succeedAgentReady()
        try await startTask.value

        XCTAssertEqual(conversation.state, .connected)
    }

    // MARK: - Audio Alignment

    func testAudioAlignmentInvokesCallback() async {
        final class AlignmentBox: @unchecked Sendable { var value: AudioAlignment? }
        let box = AlignmentBox()
        var callbacks = ConversationCallbacks()
        callbacks.onAudioAlignment = { box.value = $0 }
        let conversation = Conversation(dependencyProvider: dependencyProvider, callbacks: callbacks)

        let alignment = AudioAlignment(
            chars: ["H", "e", "l", "l", "o"],
            charStartTimesMs: [0, 100, 200, 300, 400],
            charDurationsMs: [100, 100, 100, 100, 100]
        )
        let audioEvent = AudioEvent(audioBase64: "base64", eventId: 1, alignment: alignment)

        await conversation._testing_handleIncomingEvent(.audio(audioEvent))

        XCTAssertEqual(box.value?.chars, ["H", "e", "l", "l", "o"])
    }
}
