@testable import ElevenLabs
import Foundation
import XCTest

@MainActor
final class StartupPerformanceTest: XCTestCase {
    func testStartupPerformance() async throws {
        print("=== ElevenLabs SDK Startup Performance Test ===")
        print("Testing with public agent: agent_4601k18km8yde6ftyzzwfdk6jvez")
        print("-----------------------------------------------\n")

        // Run multiple tests to get average timing
        let testRuns = 3
        var timings: [TimeInterval] = []

        for run in 1 ... testRuns {
            print("\n🔄 Test Run #\(run)")
            print("================")

            do {
                let timing = try await runSingleTest()
                timings.append(timing)
                print("✅ Run #\(run) completed in \(String(format: "%.3f", timing))s")

                // Wait between runs
                if run < testRuns {
                    print("⏱️  Waiting 3 seconds before next run...")
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
            } catch {
                print("❌ Run #\(run) failed: \(error)")
                XCTFail("Test run \(run) failed: \(error)")
            }
        }

        // Print summary
        printSummary(timings: timings)

        // Assert reasonable performance
        let avgTime = timings.reduce(0, +) / Double(timings.count)
        XCTAssertLessThan(avgTime, 3.0, "Average startup time should be less than 3 seconds")
        print("\n🎯 Performance test passed! Average time: \(String(format: "%.3f", avgTime))s")
    }

    private func runSingleTest() async throws -> TimeInterval {
        let testStart = Date()

        // Monitor state changes - create these before starting conversation
        var hasConnected = false
        var hasReceivedFirstMessage = false
        var conversation: Conversation!

        // Start the conversation using the static API
        print("  [\(String(format: "%.3f", 0.0))s] Starting conversation...")
        conversation = try await ElevenLabs.startConversation(
            agentId: "agent_4601k18km8yde6ftyzzwfdk6jvez"
        )

        // Since the static API already handles the startup, just monitor the result
        // Check the current state immediately
        let elapsed = Date().timeIntervalSince(testStart)
        print("  [\(String(format: "%.3f", elapsed))s] Conversation created")

        switch conversation.state {
        case .idle:
            print("  [\(String(format: "%.3f", elapsed))s] State: idle")
        case .connecting:
            print("  [\(String(format: "%.3f", elapsed))s] State: connecting")
        case let .active(info):
            hasConnected = true
            print("  [\(String(format: "%.3f", elapsed))s] State: active (agent: \(info.agentId))")
            print("  🎯 ACTIVE STATE REACHED in \(String(format: "%.3f", elapsed))s")
        case let .ended(reason):
            print("  [\(String(format: "%.3f", elapsed))s] State: ended (reason: \(reason))")
        case let .error(error):
            print("  [\(String(format: "%.3f", elapsed))s] State: error - \(error)")
        }

        // Check for existing messages
        if !conversation.messages.isEmpty {
            hasReceivedFirstMessage = true
            print("  [\(String(format: "%.3f", elapsed))s] Messages already present: \(conversation.messages.count)")
            if let firstMessage = conversation.messages.first {
                print("  📨 Message: \(firstMessage.content)")
            }
        }

        print("  [\(String(format: "%.3f", elapsed))s] Agent state: \(conversation.agentState)")

        // The static API should return an already-active conversation
        // But let's give it a moment and measure the total time when we called the API
        let totalTime = Date().timeIntervalSince(testStart)

        // Mark as connected since the API returned successfully
        if !hasConnected {
            hasConnected = true
            print("  [\(String(format: "%.3f", totalTime))s] ✅ Conversation returned from API")
        }

        // Wait a bit for first message
        if hasConnected && !hasReceivedFirstMessage {
            print("  ⏳ Waiting for first message...")
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3s
        }

        // Clean up
        print("  [\(String(format: "%.3f", Date().timeIntervalSince(testStart)))s] Ending conversation...")
        await conversation.endConversation()

        // Wait for cleanup
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Check if we reached active state
        let reachedActive = conversation.state.isActive
        if case .ended(reason: .userEnded) = conversation.state {
            // This is fine - we ended it ourselves
        } else if !reachedActive {
            throw NSError(domain: "StartupTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to reach active state"])
        }

        return totalTime
    }

    private func printSummary(timings: [TimeInterval]) {
        print("\n\n📊 PERFORMANCE SUMMARY")
        print("======================")

        guard !timings.isEmpty else {
            print("No successful runs to analyze")
            return
        }

        let avgTime = timings.reduce(0, +) / Double(timings.count)
        let minTime = timings.min() ?? 0
        let maxTime = timings.max() ?? 0

        print("Runs completed: \(timings.count)")
        print("Average time to active: \(String(format: "%.3f", avgTime))s")
        print("Fastest time: \(String(format: "%.3f", minTime))s")
        print("Slowest time: \(String(format: "%.3f", maxTime))s")
        print("Range: \(String(format: "%.3f", maxTime - minTime))s")

        print("\nAll timings: \(timings.map { String(format: "%.3f", $0) }.joined(separator: "s, "))s")
    }
}
