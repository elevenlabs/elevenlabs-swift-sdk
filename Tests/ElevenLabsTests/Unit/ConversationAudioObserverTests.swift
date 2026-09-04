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
        let agentObserver = RecordingAudioObserver()
        let micObserver = RecordingAudioObserver()
        let agentTrack = SpyAudioTrack()
        let micTrack = SpyAudioTrack()
        mockWebRTCConnectionManager.agentAudioTrack = agentTrack
        mockWebRTCConnectionManager.inputTrack = micTrack

        conversation.addAgentAudioObserver(agentObserver)
        conversation.addMicAudioObserver(micObserver)

        _ = try await conversation.startVoiceConversation(.publicAgent(id: "test-agent"))
        XCTAssertNotNil(mockWebRTCConnectionManager.onTracksChanged)

        agentTrack.render()
        micTrack.render()
        XCTAssertEqual(agentObserver.receivedBufferCount, 1)
        XCTAssertEqual(micObserver.receivedBufferCount, 1)

        let staleTracksChanged = mockWebRTCConnectionManager.onTracksChanged
        mockWebRTCConnectionManager.onDisconnectStarted = {
            agentTrack.render()
            micTrack.render()
        }

        await conversation.endConversation()
        XCTAssertEqual(agentObserver.receivedBufferCount, 1)
        XCTAssertEqual(micObserver.receivedBufferCount, 1)
        XCTAssertEqual(agentTrack.attachedRendererCount, 0)
        XCTAssertEqual(micTrack.attachedRendererCount, 0)

        staleTracksChanged?()
        await Task { @MainActor in }.value
        agentTrack.render()
        micTrack.render()
        XCTAssertEqual(agentObserver.receivedBufferCount, 1)
        XCTAssertEqual(micObserver.receivedBufferCount, 1)
    }

    func testEndPreventsLaterObserverAttachment() async throws {
        let observer = RecordingAudioObserver()
        let track = SpyAudioTrack()
        mockWebRTCConnectionManager.agentAudioTrack = track

        _ = try await conversation.startVoiceConversation(.publicAgent(id: "test-agent"))
        await conversation.endConversation()

        conversation.addAgentAudioObserver(observer)
        conversation.refreshAudioObservers()
        track.render()

        XCTAssertEqual(observer.receivedBufferCount, 0)
        XCTAssertEqual(track.attachedRendererCount, 0)
    }

    func testStartupFailureIgnoresStaleTrackChangesAfterCleanup() async {
        let lateObserver = RecordingAudioObserver()
        let agentTrack = SpyAudioTrack()
        mockWebRTCConnectionManager.agentAudioTrack = agentTrack
        mockWebRTCConnectionManager.autoSucceedAgentReady = false

        let startTask = Task {
            try await conversation.startVoiceConversation(.publicAgent(id: "test-agent"))
        }

        await mockWebRTCConnectionManager.waitUntilWaitingForAgent()

        let staleTracksChanged = mockWebRTCConnectionManager.onTracksChanged
        mockWebRTCConnectionManager.onDisconnectStarted = { [conversation] in
            conversation?.addAgentAudioObserver(lateObserver)
            staleTracksChanged?()
            await Task { @MainActor in }.value
            agentTrack.render()
        }

        mockWebRTCConnectionManager.timeoutAgentReady()
        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            let startupError = error as? ConversationStartupError
            XCTAssertEqual(startupError?.underlyingError, .agentTimeout)
        }

        XCTAssertEqual(lateObserver.receivedBufferCount, 0)
        XCTAssertEqual(agentTrack.attachedRendererCount, 0)
    }

    func testStartupCancellationDetachesObserversBeforeDisconnect() async {
        let observer = RecordingAudioObserver()
        let agentTrack = SpyAudioTrack()
        mockWebRTCConnectionManager.agentAudioTrack = agentTrack
        mockWebRTCConnectionManager.autoDeliverInitiationMetadata = false
        conversation.addAgentAudioObserver(observer)

        let startTask = Task {
            try await conversation.startVoiceConversation(.publicAgent(id: "test-agent"))
        }

        await waitForPublished(conversation.$state) {
            $0 == .connecting(.waitingForInitiationMetadata(timeout: 5))
        }
        mockWebRTCConnectionManager.onTracksChanged?()
        await Task { @MainActor in }.value
        agentTrack.render()
        XCTAssertEqual(observer.receivedBufferCount, 1)

        mockWebRTCConnectionManager.onDisconnectStarted = {
            agentTrack.render()
        }
        startTask.cancel()

        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(observer.receivedBufferCount, 1)
        XCTAssertEqual(agentTrack.attachedRendererCount, 0)
    }

    func testClientReusesDurableObserversAcrossResetWithoutReadding() async throws {
        let client = ConversationClient(dependencyProvider: dependencyProvider)
        let agentObserver = RecordingAudioObserver()
        let micObserver = RecordingAudioObserver()

        client.addAgentAudioObserver(agentObserver)
        client.addMicAudioObserver(micObserver)
        client.addAgentAudioObserver(agentObserver) // idempotent

        _ = try await client.startVoiceConversation(.publicAgent(id: "first-agent"))
        XCTAssertTrue(client.state.isConnected)

        await client.reset()
        _ = try await client.startVoiceConversation(.publicAgent(id: "second-agent"))
        XCTAssertTrue(client.state.isConnected)

        // Public remove path remains valid after the second session binds.
        client.removeAgentAudioObserver(agentObserver)
        client.removeMicAudioObserver(micObserver)
        await client.endConversation()
    }
}
