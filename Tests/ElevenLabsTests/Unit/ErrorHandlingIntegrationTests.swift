// swiftlint:disable file_length type_body_length function_body_length
@testable import ElevenLabs
import Combine
import XCTest

/// Integration tests for error handling scenarios with real ElevenLabs API
/// These tests verify that errors are properly propagated through the onError callback
///
/// NOTE: These tests require network access and may fail in sandboxed/CI environments
/// Temporarily disabled for release - re-enable when network access is configured
@MainActor
final class ErrorHandlingIntegrationTests: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        // Skip all integration tests for now
        XCTestSuite(name: "Skipped Integration Tests")
    }

    /// Public test agent that requires no authentication
    private let testAgentId = "agent_7601k95fk7q2eyfbp4bncp5znp6x"

    private var conversation: Conversation?
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        conversation = nil
        cancellables.removeAll()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        await conversation?.endConversation()
        conversation = nil
    }

    // MARK: - Helpers

    private func makeConfig(agentReadyTimeout: TimeInterval = 3.0) -> ConversationConfig {
        ConversationConfig(
            agentJoinTimeout: agentReadyTimeout,
            conversationInitTimeout: agentReadyTimeout
        )
    }

    // MARK: - Error Callback Tests

    /// Test that onError callback receives errors during connection failures
    func testOnErrorCallbackReceivesConnectionErrors() async throws {
        let errorExpectation = expectation(description: "Error callback should be called")
        let collector = ErrorCollector()

        let callbacks = ConversationCallbacks(
            onError: { error in
                print("✅ onError callback received: \(error)")
                Task { await collector.addError(error) }
                errorExpectation.fulfill()
            }
        )

        let conversation = Conversation(callbacks: callbacks)
        self.conversation = conversation
        conversation.$state
            .sink { state in
                print("📊 State: \(state)")
                Task { await collector.addState(state) }
            }
            .store(in: &cancellables)

        // Use an invalid agent ID to trigger an error
        do {
            try await conversation.startConversation(
                auth: .publicAgent(id: "invalid_agent_id_12345"),
                config: makeConfig()
            )
            XCTFail("Should have thrown an error")
        } catch {
            print("❌ Caught error: \(error)")
            // Wait a moment for the callback to fire
            await fulfillment(of: [errorExpectation], timeout: 5.0)
        }

        let capturedErrors = await collector.errors
        let capturedStartupStates = await collector.states

        // Verify error was captured
        XCTAssertFalse(capturedErrors.isEmpty, "onError callback should have been called")
        print("\n📋 Captured \(capturedErrors.count) error(s):")
        for (index, error) in capturedErrors.enumerated() {
            print("  \(index + 1). \(error.errorDescription ?? String(describing: error))")
        }

        // Verify startup state shows failure
        print("\n📊 Captured \(capturedStartupStates.count) startup state(s):")
        for (index, state) in capturedStartupStates.enumerated() {
            print("  \(index + 1). \(state)")
        }
    }

    /// Test successful connection with the test agent to verify no spurious errors
    func testSuccessfulConnectionNoErrors() async throws {
        let readyExpectation = expectation(description: "Agent ready callback should be called")
        let collector = ErrorCollector()

        let callbacks = ConversationCallbacks(
            onAgentReady: {
                print("✅ Agent ready!")
                readyExpectation.fulfill()
            },
            onError: { error in
                print("❌ Unexpected error in success test: \(error)")
                Task { await collector.addError(error) }
            }
        )

        let conversation = Conversation(callbacks: callbacks)
        self.conversation = conversation
        conversation.$state
            .sink { state in
                print("📊 State: \(state)")
                Task { await collector.addState(state) }
            }
            .store(in: &cancellables)

        do {
            try await conversation.startConversation(
                auth: .publicAgent(id: testAgentId),
                config: makeConfig(agentReadyTimeout: 10.0)
            )

            await fulfillment(of: [readyExpectation], timeout: 15.0)

            print("\n✅ Connection successful")
            print("📊 Final state: \(conversation.state)")

            let capturedErrors = await collector.errors
            let capturedStartupStates = await collector.states

            // Verify no errors were reported
            XCTAssertTrue(capturedErrors.isEmpty, "Error array should be empty")

            // Verify connection is active
            XCTAssertEqual(conversation.state, .connected, "Conversation should be connected")

            print("\n📊 Startup states (\(capturedStartupStates.count)):")
            for (index, state) in capturedStartupStates.enumerated() {
                print("  \(index + 1). \(state)")
            }

            if case .connected = conversation.state {
                print("\n⏱️ Startup complete (connected)")
            }

            // Clean disconnect
            await conversation.endConversation()

        } catch {
            XCTFail("Should not throw error for valid agent ID: \(error)")
        }
    }

    /// Test that errors during operation are reported
    func testOperationalErrorReporting() async throws {
        let readyExpectation = expectation(description: "Agent ready")
        let collector = ErrorCollector()

        let callbacks = ConversationCallbacks(
            onAgentReady: {
                readyExpectation.fulfill()
            },
            onError: { error in
                print("❌ Error reported: \(error)")
                Task { await collector.addError(error) }
            }
        )

        let conversation = Conversation(callbacks: callbacks)
        self.conversation = conversation

        try await conversation.startConversation(
            auth: .publicAgent(id: testAgentId),
            config: makeConfig(agentReadyTimeout: 10.0)
        )

        await fulfillment(of: [readyExpectation], timeout: 15.0)

        // Now try to perform operations that should fail
        print("\n🧪 Testing operational errors...")

        // Disconnect first
        await conversation.endConversation()

        // Try to send a message when disconnected - should trigger error
        do {
            try await conversation.sendMessage("Hello")
            XCTFail("Should throw error when not connected")
        } catch let error as ConversationError {
            print("✅ Caught expected error: \(error)")
            XCTAssertEqual(error, .notConnected)
        }

        let capturedErrors = await collector.errors
        print("\n📋 Operational errors captured via onError: \(capturedErrors.count)")
    }

    /// Test multiple rapid connection attempts to see error handling under stress
    func testRapidConnectionAttempts() async throws {
        print("\n🧪 Testing rapid connection attempts...")

        for attempt in 1 ... 3 {
            print("\n--- Attempt \(attempt) ---")

            let callbacks = ConversationCallbacks(
                onError: { error in
                    print("  ❌ Error: \(error)")
                }
            )

            let conversation = Conversation(callbacks: callbacks)
            conversation.$state
                .sink { state in print("  📊 State: \(state)") }
                .store(in: &cancellables)

            do {
                try await conversation.startConversation(
                    auth: .publicAgent(id: testAgentId),
                    config: makeConfig(agentReadyTimeout: 10.0)
                )

                print("  ✅ Connection \(attempt) successful")
                XCTAssertEqual(conversation.state, .connected)

                // Brief interaction
                try? await conversation.sendMessage("Test message \(attempt)")

                // Clean disconnect
                await conversation.endConversation()
                print("  ✅ Disconnected")

            } catch {
                print("  ❌ Connection \(attempt) failed: \(error)")
                XCTFail("Connection should succeed: \(error)")
            }
        }
    }

    /// Test that startup state transitions are properly reported including failures
    func testStartupStateTransitions() async throws {
        let errorExpectation = expectation(description: "Should receive error state")
        let collector = ErrorCollector()

        let callbacks = ConversationCallbacks(
            onError: { error in
                print("❌ Error: \(error)")
            }
        )

        let conversation = Conversation(callbacks: callbacks)
        self.conversation = conversation
        conversation.$state
            .sink { state in
                print("📊 State transition: \(state)")
                Task { await collector.addState(state) }

                if case .startupFailed = state {
                    errorExpectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Use invalid agent to trigger failure
        do {
            try await conversation.startConversation(
                auth: .publicAgent(id: "invalid_agent"),
                config: makeConfig()
            )
        } catch {
            // Expected
        }

        await fulfillment(of: [errorExpectation], timeout: 5.0)

        let capturedStartupStates = await collector.states

        print("\n📊 State transition sequence (\(capturedStartupStates.count) states):")
        for (index, state) in capturedStartupStates.enumerated() {
            print("  \(index + 1). \(state)")
        }

        // Verify we got expected state transitions
        XCTAssertTrue(capturedStartupStates.contains { state in
            if case .connecting(.authorizing) = state { return true }
            return false
        }, "Should have authorizing state")

        XCTAssertTrue(capturedStartupStates.contains { state in
            if case .startupFailed = state { return true }
            return false
        }, "Should have startup-failed state")
    }

    /// Test network permission error detection
    func testNetworkPermissionError() async throws {
        print("\n🧪 Testing network permission scenarios...")
        print("ℹ️ This test verifies error callbacks work for network issues")

        let collector = ErrorCollector()
        let callbacks = ConversationCallbacks(
            onError: { error in
                print("❌ Network error: \(error)")
                Task { await collector.addError(error) }
            }
        )

        let conversation = Conversation(callbacks: callbacks)
        self.conversation = conversation
        conversation.$state
            .sink { state in print("📊 State: \(state)") }
            .store(in: &cancellables)

        // Attempt connection - may succeed or fail depending on network
        do {
            try await conversation.startConversation(
                auth: .publicAgent(id: testAgentId),
                config: makeConfig()
            )
            print("✅ Connection succeeded (network available)")
            await conversation.endConversation()
        } catch {
            print("❌ Connection failed: \(error)")
            // This is okay - we're testing error reporting
        }

        let capturedErrors = await collector.errors
        print("📋 Total errors reported: \(capturedErrors.count)")
        for (index, error) in capturedErrors.enumerated() {
            print("  \(index + 1). \(error.errorDescription ?? String(describing: error))")
        }
    }
}

// swiftlint:enable file_length type_body_length function_body_length

// MARK: - Manual Test Helper

extension ErrorHandlingIntegrationTests {
    /// A test designed to be run manually to see error output in console
    func testManualErrorInspection() async throws {
        print("\n" + String(repeating: "=", count: 80))
        print("🔍 MANUAL ERROR INSPECTION TEST")
        print(String(repeating: "=", count: 80))
        print("\nThis test demonstrates error handling with clear console output.")
        print("Agent ID: \(testAgentId)\n")

        // Use actor to safely capture errors from Sendable closures
        let errorCollector = ErrorCollector()

        let callbacks = ConversationCallbacks(
            onAgentReady: {
                let timestamp = Self.formatTimestamp()
                print("✅ [\(timestamp)] AGENT READY")
            },
            onDisconnect: { reason in
                let timestamp = Self.formatTimestamp()
                print("🔌 [\(timestamp)] DISCONNECTED (reason: \(reason))")
            },
            onError: { error in
                let timestamp = Self.formatTimestamp()
                print("\n❌ [\(timestamp)] ERROR CALLBACK INVOKED:")
                print("   Type: \(type(of: error))")
                print("   Description: \(error.errorDescription ?? "No description")")
                print("   Error: \(error)")
                Task {
                    await errorCollector.addError(error)
                }
            }
        )

        let conversation = Conversation(callbacks: callbacks)
        self.conversation = conversation
        conversation.$state
            .sink { state in
                let timestamp = Self.formatTimestamp()
                print("📊 [\(timestamp)] STATE: \(state)")
                Task {
                    await errorCollector.addState(state)
                }
            }
            .store(in: &cancellables)

        print("\n🚀 Starting connection...")

        do {
            try await conversation.startConversation(
                auth: .publicAgent(id: testAgentId),
                config: makeConfig(agentReadyTimeout: 10.0)
            )

            print("\n✅ CONNECTION SUCCESSFUL")
            print("   State: \(conversation.state)")

            // Try some operations
            print("\n🧪 Testing operations...")

            try await conversation.sendMessage("Hello, this is a test message!")
            print("   ✅ Message sent")

            // Wait a bit
            try await Task.sleep(nanoseconds: 2_000_000_000)

            print("\n🔌 Disconnecting...")
            await conversation.endConversation()

        } catch {
            print("\n❌ CONNECTION FAILED")
            print("   Error: \(error)")
        }

        let allErrors = await errorCollector.errors
        let allStates = await errorCollector.states

        print("\n" + String(repeating: "=", count: 80))
        print("📊 SUMMARY")
        print(String(repeating: "=", count: 80))
        print("Total errors captured: \(allErrors.count)")
        print("Total state transitions: \(allStates.count)")

        if !allErrors.isEmpty {
            print("\n❌ Errors:")
            for (index, error) in allErrors.enumerated() {
                print("   \(index + 1). \(error.errorDescription ?? String(describing: error))")
            }
        }

        print("\n📊 State transition sequence:")
        for (index, state) in allStates.enumerated() {
            print("   \(index + 1). \(state)")
        }

        print(String(repeating: "=", count: 80) + "\n")
    }

    /// Helper to format timestamp for iOS 13+ compatibility
    private nonisolated static func formatTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: Date())
    }
}

/// Actor to safely collect errors from Sendable closures
private actor ErrorCollector {
    var errors: [ConversationError] = []
    var states: [ConversationState] = []

    func addError(_ error: ConversationError) {
        errors.append(error)
    }

    func addState(_ state: ConversationState) {
        states.append(state)
    }
}
