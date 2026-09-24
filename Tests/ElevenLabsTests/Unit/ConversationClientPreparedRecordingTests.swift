@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationClientPreparedRecordingTests: XCTestCase {
    private var modes: [Bool] = []
    private var client: ConversationClient!

    override func setUp() async throws {
        modes = []
        client = ConversationClient(
            dependencyProvider: TestDependencyProvider(),
            setRecordingAlwaysPreparedMode: { [weak self] in self?.modes.append($0) }
        )
    }

    override func tearDown() async throws {
        client = nil
    }

    func testVoiceConversationPreparesThenReleasesOnEnd() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"))
        await client.endConversation()

        XCTAssertEqual(modes, [true, false])
    }

    func testResetReleasesBeforeReturning() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"))
        await client.reset()

        XCTAssertEqual(modes, [true, false])
    }

    func testRestartStaysPrepared() async throws {
        _ = try await client.startVoiceConversation(.publicAgent(id: "first"))
        _ = try await client.startVoiceConversation(.publicAgent(id: "second"))
        await client.endConversation()

        XCTAssertEqual(modes, [true, false])
    }

    func testExplicitFalseNeverPrepares() async throws {
        let config = ConversationConfig(
            audioConfiguration: AudioPipelineConfiguration(preparesMicrophone: false)
        )
        _ = try await client.startVoiceConversation(.publicAgent(id: "agent"), config: config)
        await client.endConversation()

        XCTAssertEqual(modes, [])
    }

    func testTextOnlyNeverPrepares() async throws {
        _ = try await client.startTextOnlyConversation(.publicAgent(id: "agent"))
        await client.endConversation()

        XCTAssertEqual(modes, [])
    }
}
