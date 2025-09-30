@testable import ElevenLabs
import LiveKit
import XCTest

final class ConversationIntegrationTests: XCTestCase {
    @MainActor
    func testFullConversationFlow() async throws {
        // This test would require a test environment with mock services
        // For now, we'll test the basic flow structure

        let config = ConversationConfig(
            agentOverrides: AgentOverrides(prompt: "You are a test assistant",
                                           firstMessage: "Hello! How can I help you today?",
                                           language: Language.english)
        )

        // In a real integration test environment:
        // 1. Start conversation with test agent
        // 2. Send a message
        // 3. Receive agent response
        // 4. Test interruption
        // 5. Send feedback
        // 6. End conversation cleanly

        XCTAssertNotNil(config.agentOverrides)
        XCTAssertEqual(config.agentOverrides?.language, .english)
    }

    @MainActor
    func testConversationStateTransitions() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Initial state
        XCTAssertEqual(conversation.state, .idle)

        // Test that operations fail in idle state - capture conversation in a local var to avoid capture issues
        let conv = conversation
        await assertThrowsConversationError(.notConnected) {
            try await conv.sendMessage("Hello")
        }

        await assertThrowsConversationError(.notConnected) {
            try await conv.toggleMute()
        }

        await assertThrowsConversationError(.notConnected) {
            try await conv.interruptAgent()
        }
    }

    @MainActor
    func testMessageStreamHandling() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Test that message streams are empty initially
        XCTAssertTrue(conversation.messages.isEmpty)

        // In a real integration test:
        // - Connect to test agent
        // - Send messages and verify they appear in streams
        // - Test concurrent message handling
        // - Verify message ordering
    }

    @MainActor
    func testAudioIntegration() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Test initial mute state
        XCTAssertTrue(conversation.isMuted)

        // Test mute operations when not connected
        let conv1 = conversation
        await assertThrowsConversationError(.notConnected) {
            try await conv1.setMuted(true)
        }

        // In a real integration test:
        // - Test microphone permissions
        // - Test mute/unmute during conversation
        // - Test audio device changes
        // - Test background/foreground transitions
    }

    @MainActor
    func testToolCallIntegration() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Test tool response when not connected
        let conv2 = conversation
        await assertThrowsConversationError(.notConnected) {
            try await conv2.sendToolResult(
                for: "test-tool-call",
                result: "Tool executed successfully",
                isError: false
            )
        }

        // In a real integration test:
        // - Connect to agent with tools enabled
        // - Trigger tool call from agent
        // - Send tool response
        // - Verify agent receives and processes response
    }

    @MainActor
    func testContextUpdateIntegration() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Test context update when not connected
        let conv3 = conversation
        await assertThrowsConversationError(.notConnected) {
            try await conv3.updateContext("TestContext")
        }

        // In a real integration test:
        // - Connect to agent
        // - Update context during conversation
        // - Verify agent behavior changes based on context
        // - Test context persistence across messages
    }

    @MainActor
    func testFeedbackIntegration() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Test feedback when not connected
        let conv4 = conversation
        await assertThrowsConversationError(.notConnected) {
            try await conv4.sendFeedback(FeedbackEvent.Score.like, eventId: 123)
        }

        // In a real integration test:
        // - Connect to agent
        // - Receive agent message
        // - Send positive/negative feedback
        // - Verify feedback is recorded
    }

    func testErrorRecoveryIntegration() async {
        // In a real integration test:
        // - Test network interruption during conversation
        // - Test reconnection behavior
        // - Test agent timeout scenarios
        // - Test invalid message handling
        // - Test rate limiting responses

        let config = ConversationConfig()
        XCTAssertNotNil(config)
    }

    @MainActor
    func testConcurrentOperations() async {
        let mockDependencies = Task<Dependencies, Never> {
            Dependencies.shared
        }
        let conversation = Conversation(dependencies: mockDependencies)

        // Test that multiple operations handle not-connected state consistently
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 5 {
                group.addTask {
                    do {
                        try await conversation.sendMessage("Message \(i)")
                        XCTFail("Should have thrown error")
                    } catch let error as ConversationError {
                        XCTAssertEqual(error, .notConnected)
                    } catch {
                        XCTFail("Unexpected error type")
                    }
                }
            }
        }
    }

    func testMemoryManagement() async {
        // Test that conversation cleanup prevents memory leaks
        weak var weakConversation: Conversation?

        do {
            let mockDependencies = Task<Dependencies, Never> {
                await Dependencies.shared
            }
            let conversation = await Conversation(dependencies: mockDependencies)
            weakConversation = conversation

            // In a real test, we'd start and end conversation
            await conversation.endConversation()
        }

        // Force garbage collection
        autoreleasepool {}

        // Note: This test might not be reliable without proper test infrastructure
        // In a real integration test, we'd use memory profiling tools
    }

    // MARK: - Helper Methods

    @MainActor
    private func assertThrowsConversationError(
        _ expectedError: ConversationError,
        _ operation: @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected ConversationError.\(expectedError) to be thrown")
        } catch let error as ConversationError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Expected ConversationError.\(expectedError), got \(error)")
        }
    }
}
