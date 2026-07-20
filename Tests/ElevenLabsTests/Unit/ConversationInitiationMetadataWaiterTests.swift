@testable import ElevenLabs
import XCTest

final class ConversationInitiationMetadataWaiterTests: XCTestCase {
    func testMetadataReceivedBeforeWait() async throws {
        let waiter = ConversationInitiationMetadataWaiter(timeout: 1)
        await waiter.observe(makeMetadata(conversationId: "early"))

        let metadata = try await waiter.wait()

        XCTAssertEqual(metadata.conversationId, "early")
    }

    func testFirstMetadataWins() async throws {
        let waiter = ConversationInitiationMetadataWaiter(timeout: 1)
        await waiter.observe(makeMetadata(conversationId: "first"))
        await waiter.observe(makeMetadata(conversationId: "second"))

        let metadata = try await waiter.wait()

        XCTAssertEqual(metadata.conversationId, "first")
    }

    func testTimeout() async {
        let waiter = ConversationInitiationMetadataWaiter(timeout: 0.01)

        await XCTAssertThrowsErrorAsync {
            try await waiter.wait()
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .initiationMetadataTimeout)
        }
    }

    func testTimeoutIsTerminal() async {
        let waiter = ConversationInitiationMetadataWaiter(timeout: 0)

        await XCTAssertThrowsErrorAsync {
            try await waiter.wait()
        }
        await waiter.observe(makeMetadata(conversationId: "late"))
        await XCTAssertThrowsErrorAsync {
            try await waiter.wait()
        } errorHandler: { error in
            XCTAssertEqual(error as? ConversationError, .initiationMetadataTimeout)
        }
    }

    func testCancellationIsTerminal() async {
        let waiter = ConversationInitiationMetadataWaiter(timeout: 1)
        let waitTask = Task { try await waiter.wait() }

        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await waiter.observe(makeMetadata(conversationId: "late"))
        await XCTAssertThrowsErrorAsync {
            try await waiter.wait()
        } errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func makeMetadata(conversationId: String) -> ConversationMetadataEvent {
        ConversationMetadataEvent(
            conversationId: conversationId,
            agentOutputAudioFormat: "pcm_16000",
            userInputAudioFormat: "pcm_16000"
        )
    }
}
