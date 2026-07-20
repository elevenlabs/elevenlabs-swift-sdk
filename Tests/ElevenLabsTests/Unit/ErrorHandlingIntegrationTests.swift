// swiftlint:disable file_length type_body_length function_body_length
import Combine
@testable import ElevenLabs
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

    override func setUp() async throws {
        conversation = nil
    }

    override func tearDown() async throws {
        await conversation?.endConversation()
        conversation = nil
    }

    // MARK: - Error Callback Tests

    /// Test that onError callback receives errors during connection failures
    func testOnErrorCallbackReceivesConnectionErrors() async throws {
        let errorExpectation = expectation(description: "Error callback should be called")
        let collector = ErrorCollector()

        let config = ConversationConfig()
        let callbacks = ConversationCallbacks(
            onError: { error in
                print("✅ onError callback received: \(error)")
                Task { await collector.addError(error) }
                errorExpectation.fulfill()
            }
        )

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        // Use an invalid agent ID to trigger an error
        do {
            try await conversation.startConversation(
                auth: ConversationCredentials.publicAgent(id: "invalid_agent_id_12345"),
                config: config
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

        // Increase timeout for real network conditions
        let startupConfig = ConversationStartupConfiguration(agentReadyTimeout: 10.0) // Increased from default 3.0

        // Use automatic network strategy for faster test connections (allows all connection types)
        let networkConfig = WebRTCConfiguration(strategy: .automatic)

        let config = ConversationConfig(
            startupConfiguration: startupConfig,
            networkConfiguration: networkConfig
        )
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

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        do {
            try await conversation.startConversation(
                auth: ConversationCredentials.publicAgent(id: testAgentId),
                config: config
            )

            await fulfillment(of: [readyExpectation], timeout: 15.0)

            print("\n✅ Connection successful")
            print("📊 Final state: \(conversation.state)")

            let capturedErrors = await collector.errors
            let capturedStartupStates = await collector.states

            // Verify no errors were reported
            XCTAssertTrue(capturedErrors.isEmpty, "Error array should be empty")

            // Verify connection is established
            XCTAssertTrue(conversation.state.isConnected, "Conversation should be connected")

            print("\n📊 Startup states (\(capturedStartupStates.count)):")
            for (index, state) in capturedStartupStates.enumerated() {
                print("  \(index + 1). \(state)")
            }

            if case let .connected(_, metrics) = conversation.state {
                print("\n⏱️ Startup metrics:")
                print("  Total: \(String(format: "%.3f", metrics.total ?? 0))s")
                print("  Token fetch: \(String(format: "%.3f", metrics.tokenFetch ?? 0))s")
                print("  Room connect: \(String(format: "%.3f", metrics.roomConnect ?? 0))s")
                print("  Agent ready: \(String(format: "%.3f", metrics.agentReady ?? 0))s")
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

        // Increase timeout for real network conditions
        let startupConfig = ConversationStartupConfiguration(agentReadyTimeout: 10.0)

        // Use automatic network strategy for faster test connections
        let networkConfig = WebRTCConfiguration(strategy: .automatic)

        let config = ConversationConfig(
            startupConfiguration: startupConfig,
            networkConfiguration: networkConfig
        )
        let callbacks = ConversationCallbacks(
            onAgentReady: {
                readyExpectation.fulfill()
            },
            onError: { error in
                print("❌ Error reported: \(error)")
                Task { await collector.addError(error) }
            }
        )

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        try await conversation.startConversation(
            auth: ConversationCredentials.publicAgent(id: testAgentId),
            config: config
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

        // Increase timeout for real network conditions
        let startupConfig = ConversationStartupConfiguration(agentReadyTimeout: 10.0)

        // Use automatic network strategy for faster test connections
        let networkConfig = WebRTCConfiguration(strategy: .automatic)

        for attempt in 1 ... 3 {
            print("\n--- Attempt \(attempt) ---")

            let config = ConversationConfig(
                startupConfiguration: startupConfig,
                networkConfiguration: networkConfig
            )
            let callbacks = ConversationCallbacks(
                onError: { error in
                    print("  ❌ Error: \(error)")
                }
            )

            let conversation = Conversation(
                dependencyProvider: Dependencies(),
                config: config,
                callbacks: callbacks
            )

            do {
                try await conversation.startConversation(
                    auth: ConversationCredentials.publicAgent(id: testAgentId),
                    config: config
                )

                print("  ✅ Connection \(attempt) successful")
                XCTAssertTrue(conversation.state.isConnected)

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

    /// Test that startup stages are reported and failures land in `.error`.
    func testStartupStateTransitions() async throws {
        let errorExpectation = expectation(description: "Should receive error callback")

        let config = ConversationConfig()
        let callbacks = ConversationCallbacks(
            onError: { error in
                print("❌ Error: \(error)")
                errorExpectation.fulfill()
            }
        )

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        var observedResolvingToken = false
        var cancellable: AnyCancellable?
        cancellable = conversation.$state.sink { state in
            if case .connecting(.resolvingToken) = state {
                observedResolvingToken = true
            }
        }

        // Use invalid agent to trigger failure
        do {
            try await conversation.startConversation(
                auth: ConversationCredentials.publicAgent(id: "invalid_agent"),
                config: config
            )
        } catch {
            // Expected
        }
        cancellable?.cancel()

        await fulfillment(of: [errorExpectation], timeout: 5.0)

        XCTAssertTrue(observedResolvingToken, "Should have resolvingToken stage")

        guard case .error = conversation.state else {
            return XCTFail("Expected error state after startup failure")
        }
    }

    /// Test custom token provider error handling
    func testCustomTokenProviderError() async throws {
        let errorExpectation = expectation(description: "Should receive error")
        let collector = ErrorCollector()

        let config = ConversationConfig()
        let callbacks = ConversationCallbacks(
            onError: { error in
                print("❌ Token provider error: \(error)")
                Task { await collector.addError(error) }
                errorExpectation.fulfill()
            }
        )

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        // Provide a token provider that throws an error
        do {
            try await conversation.startConversation(
                auth: .customTokenProvider {
                    throw NSError(domain: "TestError", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: "Custom token provider failed"
                    ])
                },
                config: config
            )
            XCTFail("Should have thrown error")
        } catch {
            print("✅ Caught error: \(error)")
        }

        await fulfillment(of: [errorExpectation], timeout: 5.0)

        let capturedErrors = await collector.errors
        XCTAssertFalse(capturedErrors.isEmpty, "Error callback should have been invoked")
        print("📋 Final captured error: \(capturedErrors.first?.errorDescription ?? "none")")
    }

    /// Test network permission error detection
    func testNetworkPermissionError() async throws {
        print("\n🧪 Testing network permission scenarios...")
        print("ℹ️ This test verifies error callbacks work for network issues")

        let collector = ErrorCollector()
        let config = ConversationConfig()
        let callbacks = ConversationCallbacks(
            onError: { error in
                print("❌ Network error: \(error)")
                Task { await collector.addError(error) }
            }
        )

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        // Attempt connection - may succeed or fail depending on network
        do {
            try await conversation.startConversation(
                auth: ConversationCredentials.publicAgent(id: testAgentId),
                config: config
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

        // Increase timeout for real network conditions
        let startupConfig = ConversationStartupConfiguration(agentReadyTimeout: 10.0)

        // Use automatic network strategy for faster test connections
        let networkConfig = WebRTCConfiguration(strategy: .automatic)

        let config = ConversationConfig(
            startupConfiguration: startupConfig,
            networkConfiguration: networkConfig
        )
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

        let conversation = Conversation(
            dependencyProvider: Dependencies(),
            config: config,
            callbacks: callbacks
        )
        self.conversation = conversation

        print("\n🚀 Starting connection...")

        do {
            try await conversation.startConversation(
                auth: ConversationCredentials.publicAgent(id: testAgentId),
                config: config
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
    var states: [ConversationStartupState] = []

    func addError(_ error: ConversationError) {
        errors.append(error)
    }

    func addState(_ state: ConversationStartupState) {
        states.append(state)
    }
}
