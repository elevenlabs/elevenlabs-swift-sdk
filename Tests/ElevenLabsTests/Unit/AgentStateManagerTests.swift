@testable import ElevenLabs
import XCTest

@MainActor
final class AgentStateManagerTests: XCTestCase {
    private var manager: AgentStateManager!

    override func setUp() async throws {
        let config = AgentStateConfiguration(
            useEventBasedState: true,
            minSpeechDuration: 0.05,
            minSilenceDuration: 0.05,
            speakingToListeningDelay: 0.05
        )
        manager = AgentStateManager(configuration: config, logger: MockLogger())
    }

    func testUserTranscriptTransitionsToThinking() {
        manager.processSignal(.userTranscript)
        XCTAssertEqual(manager.currentState, .thinking)
    }

    func testUserTranscriptWhileSpeakingDoesNotTransition() {
        manager.processSignal(.agentStartedSpeaking)
        manager.processSignal(.userTranscript)
        XCTAssertEqual(manager.currentState, .speaking)
    }

    func testInterruptionTransitionsToListening() {
        manager.processSignal(.agentStartedSpeaking)
        manager.processSignal(.interruption)
        XCTAssertEqual(manager.currentState, .listening)
    }

    func testToolRequestAndResponse() {
        manager.processSignal(.agentToolRequest)
        XCTAssertEqual(manager.currentState, .thinking)

        manager.processSignal(.agentToolResponse)
        XCTAssertEqual(manager.currentState, .listening)
    }

    func testTypicalConversationFlow() async throws {
        manager.processSignal(.vadScore(0.8))
        try await Task.sleep(nanoseconds: 100_000_000)
        manager.processSignal(.vadScore(0.1))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.currentState, .thinking)

        manager.processSignal(.agentResponse)
        XCTAssertEqual(manager.currentState, .speaking)

        manager.processSignal(.agentStoppedSpeaking)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.currentState, .listening)
    }
}

private final class MockLogger: Logging {
    nonisolated func log(level _: ElevenLabs.LogLevel, message _: String, context _: [String: String]?) {}
    nonisolated func trace(_: String, context _: [String: String]?) {}
    nonisolated func debug(_: String, context _: [String: String]?) {}
    nonisolated func info(_: String, context _: [String: String]?) {}
    nonisolated func warning(_: String, context _: [String: String]?) {}
    nonisolated func error(_: String, context _: [String: String]?) {}
}
