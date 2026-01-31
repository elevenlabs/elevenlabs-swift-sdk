@testable import ElevenLabs
import XCTest

final class ConversationStartupTrackerTests: XCTestCase {
    func testTracksTokenFetchAndTotalDurations() throws {
        let clock = TestClock(sequence: [0.0, 0.05, 0.07, 0.12])
        var tracker = ConversationStartupTracker(now: { clock.next() })

        tracker.markTokenFetchStarted()
        tracker.markTokenFetchCompleted()
        tracker.finalizeTotal()

        XCTAssertEqual(try XCTUnwrap(tracker.metrics.tokenFetch), 0.02, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tracker.metrics.total), 0.12, accuracy: 1e-6)
    }

    func testRecordsConversationInitAttemptAndDuration() throws {
        let clock = TestClock(sequence: [0.0, 0.2, 0.25, 0.35])
        var tracker = ConversationStartupTracker(now: { clock.next() })

        tracker.recordConversationInitAttempt(2)
        tracker.markConversationInitStarted()
        tracker.markConversationInitFinished()

        XCTAssertEqual(tracker.metrics.conversationInitAttempts, 2)
        XCTAssertEqual(try XCTUnwrap(tracker.metrics.conversationInit), 0.05, accuracy: 1e-6)
    }

    func testTracksAgentReadyOutcomes() {
        let clock = TestClock(sequence: [0.0, 0.0])
        var tracker = ConversationStartupTracker(now: { clock.next() })

        tracker.markAgentReadySuccess(detail: AgentReadyDetail(elapsed: 0.4, viaGraceTimeout: true))
        tracker.recordAgentReadyBuffer(seconds: 0.15)

        XCTAssertEqual(tracker.metrics.agentReady, 0.4)
        XCTAssertTrue(tracker.metrics.agentReadyViaGraceTimeout)
        XCTAssertEqual(tracker.metrics.agentReadyBuffer, 0.15)

        tracker.markAgentReadyTimeout(elapsed: 1.0)
        XCTAssertEqual(tracker.metrics.agentReady, 1.0)
        XCTAssertTrue(tracker.metrics.agentReadyTimedOut)
    }
}

private final class TestClock: @unchecked Sendable {
    private let values: [TimeInterval]
    private var index = 0
    private let base = Date(timeIntervalSince1970: 0)

    init(sequence: [TimeInterval]) {
        values = sequence
    }

    func next() -> Date {
        precondition(index < values.count, "Not enough timestamps supplied to TestClock")
        defer { index += 1 }
        return base.addingTimeInterval(values[index])
    }
}
