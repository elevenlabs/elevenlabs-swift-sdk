import Accelerate
import AVFoundation
@testable import ElevenLabs
@testable import LiveKit
import LiveKitWebRTC
import XCTest

final class SoftwareMuteProcessorTests: XCTestCase {
    func testDoesNothingIfUnmuted() throws {
        let expectation = expectation(description: "should not fire while unmuted")
        expectation.isInverted = true

        let processor = SoftwareMuteProcessor(
            onMutedSpeech: { _ in
                expectation.fulfill()
            },
            mutedSpeechThrottleInSeconds: 0
        )

        try processor.audioProcessingProcess(audioBuffer: loadBuffer(named: "spoken-audio"))
        wait(for: [expectation], timeout: 0.5)
    }

    func testDoesNothingIfAudioIsSilent() throws {
        let expectation = expectation(description: "should not fire when audio is silent")
        expectation.isInverted = true

        let processor = SoftwareMuteProcessor(
            onMutedSpeech: { _ in
                expectation.fulfill()
            },
            mutedSpeechThrottleInSeconds: 0
        )

        processor.setMuted(true)
        try processor.audioProcessingProcess(audioBuffer: loadBuffer(named: "silence"))
        wait(for: [expectation], timeout: 0.5)
    }

    func testDetectsSpokenTextWhenMuted() throws {
        let expectation = expectation(description: "should fire")

        let processor = SoftwareMuteProcessor(
            onMutedSpeech: { _ in
                expectation.fulfill()
            },
            mutedSpeechThrottleInSeconds: 0
        )

        processor.setMuted(true)
        try processor.audioProcessingProcess(audioBuffer: loadBuffer(named: "spoken-audio"))
        wait(for: [expectation], timeout: 2.0)
    }

    func testDoesNotChangeBufferedDataIfUnmuted() throws {
        let processor = SoftwareMuteProcessor(
            onMutedSpeech: { _ in },
            mutedSpeechThrottleInSeconds: 0
        )

        let buffer = try loadBuffer(named: "spoken-audio")
        processor.audioProcessingProcess(audioBuffer: buffer)

        let buffer2 = try loadBuffer(named: "spoken-audio")
        XCTAssertEqual(buffer.channels, buffer2.channels)
        XCTAssertEqual(buffer.frames, buffer2.frames)
        for ch in 0 ..< buffer.channels {
            let ptr1 = buffer.rawBuffer(forChannel: ch)
            let ptr2 = buffer2.rawBuffer(forChannel: ch)
            for f in 0 ..< buffer.frames {
                XCTAssertEqual(ptr1[f], ptr2[f], "Mismatch at channel \(ch), frame \(f)")
            }
        }
    }

    func testZerosBufferedDataIfMuted() throws {
        let processor = SoftwareMuteProcessor(
            onMutedSpeech: { _ in },
            mutedSpeechThrottleInSeconds: 0
        )

        let buffer = try loadBuffer(named: "spoken-audio")
        processor.setMuted(true)
        processor.audioProcessingProcess(audioBuffer: buffer)

        for ch in 0 ..< buffer.channels {
            let ptr1 = buffer.rawBuffer(forChannel: ch)
            for f in 0 ..< buffer.frames {
                XCTAssertEqual(ptr1[f], 0, "unzeroed data at channel \(ch), frame \(f)")
            }
        }
    }

    func loadBuffer(named bufferName: String) throws -> LKAudioBuffer {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: bufferName, withExtension: "mp3", subdirectory: "Resources"),
            "Missing test resource: \(bufferName).mp3"
        )
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat
        let targetSampleRate: Double = 48000

        guard let float32Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: fileFormat.channelCount,
            interleaved: false
        ) else {
            throw NSError(domain: "Test", code: 1)
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "Test", code: 2)
        }
        try file.read(into: readBuffer)

        let outputBuffer: AVAudioPCMBuffer
        if fileFormat.sampleRate != targetSampleRate || fileFormat.commonFormat != .pcmFormatFloat32 {
            guard let converter = AVAudioConverter(from: fileFormat, to: float32Format),
                  let converted = AVAudioPCMBuffer(
                      pcmFormat: float32Format,
                      frameCapacity: AVAudioFrameCount(Double(frameCount) * targetSampleRate / fileFormat
                          .sampleRate)
                  )
            else {
                throw NSError(domain: "Test", code: 3)
            }
            var isDone = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if isDone { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData; isDone = true; return readBuffer
            }
            var error: NSError?
            converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
            if let error { throw error }
            outputBuffer = converted
        } else {
            outputBuffer = readBuffer
        }

        guard let floatData = outputBuffer.floatChannelData else {
            throw NSError(domain: "Test", code: 4)
        }

        let channels = Int(float32Format.channelCount)
        let frames = Int(outputBuffer.frameLength)

        var scale: Float = 32768.0
        var pointers: [UnsafeMutablePointer<Float>] = []
        for ch in 0 ..< channels {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            vDSP_vsmul(floatData[ch], 1, &scale, buf, 1, vDSP_Length(frames))
            pointers.append(buf)
        }

        let mock = MockRTCAudioBuffer(channels: channels, frames: frames, buffers: pointers)
        return LKAudioBuffer(audioBuffer: mock)
    }

    class MockRTCAudioBuffer: LKRTCAudioBuffer {
        private let _channels: Int
        private let _frames: Int
        private let buffers: [UnsafeMutablePointer<Float>]

        init(channels: Int, frames: Int, buffers: [UnsafeMutablePointer<Float>]) {
            _channels = channels
            _frames = frames
            self.buffers = buffers
            super.init()
        }

        override var channels: Int {
            _channels
        }

        override var frames: Int {
            _frames
        }

        override var framesPerBand: Int {
            _frames
        }

        override var bands: Int {
            1
        }

        override func rawBuffer(forChannel channel: Int) -> UnsafeMutablePointer<Float> {
            buffers[channel]
        }
    }
}
