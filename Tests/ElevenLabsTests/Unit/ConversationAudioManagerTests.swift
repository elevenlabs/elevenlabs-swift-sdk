@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationAudioManagerTests: XCTestCase {
    func testDefaultPreparationIsAppliedDuringConfigureAndDisabledDuringCleanup() async {
        var preparedModes: [Bool] = []
        let manager = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            recordingPreparationCoordinator: RecordingPreparationCoordinator(),
            setRecordingAlwaysPreparedMode: { preparedModes.append($0) }
        )

        XCTAssertTrue(preparedModes.isEmpty)

        await manager.configure(with: .init(), callbacks: .init())
        XCTAssertEqual(preparedModes, [true])

        await manager.cleanup()
        XCTAssertEqual(preparedModes, [true, false])
    }

    func testExplicitNilPreparationIsPreservedUntilCleanup() async {
        var preparedModes: [Bool] = []
        let manager = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            recordingPreparationCoordinator: RecordingPreparationCoordinator(),
            setRecordingAlwaysPreparedMode: { preparedModes.append($0) }
        )
        let config = ConversationConfig(
            audioConfiguration: AudioPipelineConfiguration(recordingAlwaysPrepared: nil)
        )

        await manager.configure(with: config, callbacks: .init())
        XCTAssertTrue(preparedModes.isEmpty)

        await manager.cleanup()
        XCTAssertTrue(preparedModes.isEmpty)
    }

    func testExplicitFalsePreparationIsAppliedOnce() async {
        var preparedModes: [Bool] = []
        let manager = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            recordingPreparationCoordinator: RecordingPreparationCoordinator(),
            setRecordingAlwaysPreparedMode: { preparedModes.append($0) }
        )
        let config = ConversationConfig(
            audioConfiguration: AudioPipelineConfiguration(recordingAlwaysPrepared: false)
        )

        await manager.configure(with: config, callbacks: .init())
        await manager.cleanup()

        XCTAssertEqual(preparedModes, [false])
    }

    func testPreparationRemainsEnabledUntilLastWarmSessionEnds() async {
        var preparedModes: [Bool] = []
        let coordinator = RecordingPreparationCoordinator()
        let apply: @MainActor (Bool) async throws -> Void = { preparedModes.append($0) }
        let first = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            recordingPreparationCoordinator: coordinator,
            setRecordingAlwaysPreparedMode: apply
        )
        let second = ConversationAudioManager(
            logger: SDKLogger(logLevel: .error),
            recordingPreparationCoordinator: coordinator,
            setRecordingAlwaysPreparedMode: apply
        )

        await first.configure(with: .init(), callbacks: .init())
        await second.configure(with: .init(), callbacks: .init())
        XCTAssertEqual(preparedModes, [true])

        await first.cleanup()
        XCTAssertEqual(preparedModes, [true])

        await second.cleanup()
        XCTAssertEqual(preparedModes, [true, false])
    }
}
