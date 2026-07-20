import AVFoundation
@testable import ElevenLabs
import XCTest

@MainActor
final class ConversationAudioLevelMonitorTests: XCTestCase {
    func testDefaultBandMirrorsAverageLevel() async throws {
        let monitor = ConversationAudioLevelMonitor()

        monitor.didReceive(makeBuffer(samples: Array(repeating: 0.5, count: 480)))

        let levels = try await waitForLevels(from: monitor)
        XCTAssertEqual(levels.bands.count, 1)
        XCTAssertEqual(levels.bands[0], levels.average)
    }

    func testFrequencyBandsIdentifyDominantRange() async throws {
        let monitor = ConversationAudioLevelMonitor(bandCount: 4)
        let sampleRate: Float = 48000
        let samples = (0 ..< 1024).map {
            sin(2 * .pi * 440 * Float($0) / sampleRate)
        }

        monitor.didReceive(makeBuffer(samples: samples, sampleRate: Double(sampleRate)))

        let levels = try await waitForLevels(from: monitor) {
            $0.bands.contains { $0 > 0 }
        }
        XCTAssertEqual(levels.bands.count, 4)
        XCTAssertEqual(levels.bands.indices.max(by: {
            levels.bands[$0] < levels.bands[$1]
        }), 0)
        XCTAssertEqual(levels.average, levels.bands.reduce(0, +) / 4)
    }

    func testResetClearsLatestLevels() async throws {
        let monitor = ConversationAudioLevelMonitor(bandCount: 3)
        monitor.didReceive(makeBuffer(samples: Array(repeating: 0.5, count: 1024)))
        _ = try await waitForLevels(from: monitor)

        monitor.reset()

        XCTAssertEqual(monitor.current, .silent)
    }

    private func waitForLevels(
        from monitor: ConversationAudioLevelMonitor,
        matching predicate: (ConversationAudioLevels) -> Bool = { $0.average > 0 }
    ) async throws -> ConversationAudioLevels {
        for _ in 0 ..< 100 {
            let levels = monitor.current
            if predicate(levels) {
                return levels
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for audio levels")
        return monitor.current
    }

    private func makeBuffer(
        samples: [Float],
        sampleRate: Double = 48000
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = buffer.frameCapacity

        for index in samples.indices {
            buffer.floatChannelData![0][index] = samples[index]
        }
        return buffer
    }
}
