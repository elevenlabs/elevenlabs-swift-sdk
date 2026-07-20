import AVFoundation
@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationAudioObserverTests: XCTestCase {
    private var conversation: Conversation!
    private var mockWebRTCConnectionManager: MockWebRTCConnectionManager!
    private var dependencyProvider: TestDependencyProvider!

    override func setUp() async throws {
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        dependencyProvider = TestDependencyProvider(
            webRTCConnectionManager: mockWebRTCConnectionManager,
            webSocketConnectionManager: MockWebSocketConnectionManager()
        )
        conversation = Conversation(dependencyProvider: dependencyProvider)
    }

    override func tearDown() async throws {
        conversation = nil
        mockWebRTCConnectionManager = nil
        dependencyProvider = nil
    }

    func testSessionKeepsObserversThroughStartAndClearsThemOnEnd() async throws {
        let agentObserver = SpyAudioObserver()
        let micObserver = SpyAudioObserver()
        conversation.addAgentAudioObserver(agentObserver)
        conversation.addMicAudioObserver(micObserver)
        XCTAssertEqual(conversation.agentObserverRegistry.registeredCount, 1)
        XCTAssertEqual(conversation.micObserverRegistry.registeredCount, 1)

        _ = try await conversation.start(auth: .publicAgent(id: "test-agent"))
        XCTAssertNotNil(mockWebRTCConnectionManager.onTracksChanged)
        XCTAssertEqual(conversation.agentObserverRegistry.registeredCount, 1)
        XCTAssertEqual(conversation.micObserverRegistry.registeredCount, 1)

        await conversation.endConversation()
        XCTAssertEqual(conversation.agentObserverRegistry.registeredCount, 0)
        XCTAssertEqual(conversation.micObserverRegistry.registeredCount, 0)
    }

    func testClientReusesDurableObserversAcrossResetWithoutReadding() async throws {
        let client = ConversationClient(dependencyProvider: dependencyProvider)
        let agentObserver = SpyAudioObserver()
        let micObserver = SpyAudioObserver()

        client.addAgentAudioObserver(agentObserver)
        client.addMicAudioObserver(micObserver)
        client.addAgentAudioObserver(agentObserver) // idempotent

        _ = try await client.startConversation(auth: .publicAgent(id: "first-agent"))
        XCTAssertTrue(client.state.isConnected)

        await client.reset()
        _ = try await client.startConversation(auth: .publicAgent(id: "second-agent"))
        XCTAssertTrue(client.state.isConnected)

        // Public remove path remains valid after the second session binds.
        client.removeAgentAudioObserver(agentObserver)
        client.removeMicAudioObserver(micObserver)
        await client.endConversation()
    }
}

private final class SpyAudioObserver: ConversationAudioObserver, @unchecked Sendable {
    func didReceive(_: AVAudioPCMBuffer) {}
}
