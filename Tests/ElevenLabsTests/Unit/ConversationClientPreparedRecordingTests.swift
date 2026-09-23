@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationClientPreparedRecordingTests: XCTestCase {
    private var modes: ValueRecorder<Bool>!
    private var client: ConversationClient!

    override func setUp() async throws {
        let modes = ValueRecorder<Bool>()
        self.modes = modes
        client = ConversationClient(
            dependencyProvider: TestDependencyProvider(),
            setRecordingAlwaysPreparedMode: { await modes.append($0) }
        )
    }

    override func tearDown() async throws {
        client = nil
        modes = nil
    }

    func testVoiceConversationPreparesThenReleasesOnEnd() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"))
        await client.endConversation()

        let values = await modes.values()
        XCTAssertEqual(values, [true, false])
    }

    func testResetReleasesBeforeReturning() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"))
        await client.reset()

        let values = await modes.values()
        XCTAssertEqual(values, [true, false])
    }

    func testRestartStaysPrepared() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "first"))
        _ = try await client.startVoiceConversation(.publicAgent(id: "second"))
        await settle()

        let values = await modes.values()
        XCTAssertEqual(values, [true])
    }

    func testExplicitFalseNeverPrepares() async throws {
        let config = ConversationConfig(
            audioConfiguration: AudioPipelineConfiguration(recordingAlwaysPrepared: false)
        )
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"), config: config)
        await client.endConversation()
        await settle()

        let values = await modes.values()
        XCTAssertEqual(values, [])
    }

    func testTextOnlyNeverPrepares() async throws {
        _ = try await client.startTextOnlyConversation(.publicAgent(id: "agent"))
        await client.endConversation()
        await settle()

        let values = await modes.values()
        XCTAssertEqual(values, [])
    }

    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}
