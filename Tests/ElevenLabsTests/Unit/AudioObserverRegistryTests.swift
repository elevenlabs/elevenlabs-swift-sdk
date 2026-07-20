import AVFoundation
@testable import ElevenLabs
import XCTest

@MainActor
final class AudioObserverRegistryTests: XCTestCase {
    func testAddRemoveIsIdempotentWithoutTrack() {
        let registry = AudioObserverRegistry()
        let observer = SpyAudioObserver()

        registry.add(observer)
        registry.add(observer)
        XCTAssertEqual(registry.registeredCount, 1)

        registry.remove(observer)
        registry.remove(observer)
        XCTAssertEqual(registry.registeredCount, 0)
    }

    func testAttachToNilKeepsRegisteredObservers() {
        let registry = AudioObserverRegistry()
        let observer = SpyAudioObserver()

        registry.add(observer)
        registry.attach(to: nil)
        XCTAssertEqual(registry.registeredCount, 1)

        registry.remove(observer)
        XCTAssertEqual(registry.registeredCount, 0)
    }

    func testResetClearsRegistrations() {
        let registry = AudioObserverRegistry()
        registry.add(SpyAudioObserver())
        registry.reset()
        XCTAssertEqual(registry.registeredCount, 0)
    }

    func testAttachDeliversBuffersAndResetDetachesFromTrack() {
        let registry = AudioObserverRegistry()
        let track = SpyAudioTrack()
        let observer = RecordingAudioObserver()

        registry.add(observer)
        registry.attach(to: track)
        track.render()

        XCTAssertEqual(observer.receivedBufferCount, 1)
        XCTAssertEqual(track.addCallCount, 1)
        XCTAssertEqual(track.attachedRendererCount, 1)

        registry.reset()
        track.render()

        XCTAssertEqual(observer.receivedBufferCount, 1)
        XCTAssertEqual(track.removeCallCount, 1)
        XCTAssertEqual(track.attachedRendererCount, 0)
    }
}

private final class SpyAudioObserver: ConversationAudioObserver, @unchecked Sendable {
    func didReceive(_: AVAudioPCMBuffer) {}
}
