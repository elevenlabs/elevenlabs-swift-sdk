import AVFoundation
@testable import ElevenLabsWidget
import XCTest

final class ConversationAudioLevelMonitorTests: XCTestCase {
    private let monitor = ConversationAudioLevelMonitor()

    func testStartsSilent() {
        XCTAssertEqual(monitor.sample(), 0)
    }

    func testToneRaisesLevel() throws {
        try monitor.didReceive(tone(amplitude: 0.5))
        XCTAssertGreaterThan(monitor.sample(), 0.5)
    }

    func testLouderToneGivesHigherLevel() throws {
        try monitor.didReceive(tone(amplitude: 0.05))
        let quiet = monitor.sample()
        monitor.reset()
        try monitor.didReceive(tone(amplitude: 1))
        XCTAssertGreaterThan(monitor.sample(), quiet)
    }

    func testLevelHoldsThePeakBetweenReads() throws {
        try monitor.didReceive(tone(amplitude: 1))
        let loud = monitor.sample()
        monitor.reset()
        try monitor.didReceive(tone(amplitude: 1))
        try monitor.didReceive(tone(amplitude: 0))
        XCTAssertEqual(monitor.sample(), loud)
    }

    /// Decay is paced by reads, so a stream that stops delivering still fades.
    func testSilenceDecaysWithoutReachingZero() throws {
        try monitor.didReceive(tone(amplitude: 1))
        let loud = monitor.sample()
        let decayed = monitor.sample()
        XCTAssertLessThan(decayed, loud)
        XCTAssertGreaterThan(decayed, 0)
        XCTAssertLessThan(monitor.sample(), decayed)
    }

    func testResetClearsLevel() throws {
        try monitor.didReceive(tone(amplitude: 1))
        monitor.reset()
        XCTAssertEqual(monitor.sample(), 0)
    }

    func testEmptyBufferIsIgnored() throws {
        let buffer = try tone(amplitude: 1)
        buffer.frameLength = 0
        monitor.didReceive(buffer)
        XCTAssertEqual(monitor.sample(), 0)
    }

    func testInt16BufferRaisesLevel() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
        for frame in 0 ..< 1024 {
            samples[frame] = Int16(Float(Int16.max) * 0.5 * sin(2 * .pi * 440 * Float(frame) / 48000))
        }
        monitor.didReceive(buffer)
        XCTAssertGreaterThan(monitor.sample(), 0.5)
    }

    private func tone(amplitude: Float, frames: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0 ..< Int(frames) {
            samples[frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / 48000)
        }
        return buffer
    }
}
