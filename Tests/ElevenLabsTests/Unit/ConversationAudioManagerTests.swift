@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationAudioManagerTests: XCTestCase {
    func testDefaultPreparationIsConfiguredThenDisabled() async {
        var modes: [Bool] = []
        let manager = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            setRecordingAlwaysPreparedMode: { modes.append($0) }
        )

        XCTAssertTrue(modes.isEmpty)
        await manager.configure(with: .init(), callbacks: .init())
        await manager.cleanup()

        XCTAssertEqual(modes, [true, false])
    }

    func testExplicitFalseIsNotOverwrittenOrRestored() async {
        var modes: [Bool] = []
        let manager = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            setRecordingAlwaysPreparedMode: { modes.append($0) }
        )
        let config = ConversationConfig(
            audioConfiguration: AudioPipelineConfiguration(recordingAlwaysPrepared: false)
        )

        await manager.configure(with: config, callbacks: .init())
        await manager.cleanup()

        XCTAssertEqual(modes, [false])
    }
}
