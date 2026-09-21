@_spi(Testing) @testable import ElevenLabs
import XCTest

@MainActor
final class ConversationClientPreparedRecordingTests: XCTestCase {
    private var provider: TestDependencyProvider!
    private var client: ConversationClient!

    override func setUp() async throws {
        provider = TestDependencyProvider()
        client = ConversationClient(dependencyProvider: provider)
    }

    override func tearDown() async throws {
        client = nil
        provider = nil
    }

    func testVoiceConversationPreparesThenReleasesOnEnd() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"))
        await client.endConversation()

        XCTAssertEqual(provider.recordingAlwaysPreparedModes, [true, false])
    }

    func testResetReleasesBeforeReturning() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"))
        await client.reset()

        XCTAssertEqual(provider.recordingAlwaysPreparedModes, [true, false])
    }

    func testRestartStaysPrepared() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "first"))
        _ = try await client.startVoiceConversation(.publicAgent(id: "second"))
        await settle()

        XCTAssertEqual(provider.recordingAlwaysPreparedModes, [true])
    }

    func testExplicitFalseNeverPrepares() async throws {
        let config = ConversationConfig(
            audioConfiguration: AudioPipelineConfiguration(recordingAlwaysPrepared: false)
        )
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"), config: config)
        await client.endConversation()
        await settle()

        XCTAssertEqual(provider.recordingAlwaysPreparedModes, [])
    }

    func testTextOnlyNeverPrepares() async throws {
        _ = try await client.startTextOnlyConversation(.publicAgent(id: "agent"))
        await client.endConversation()
        await settle()

        XCTAssertEqual(provider.recordingAlwaysPreparedModes, [])
    }

    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}
