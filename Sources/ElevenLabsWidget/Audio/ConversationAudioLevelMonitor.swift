import Accelerate
@preconcurrency import AVFoundation
import ElevenLabs

/// Tracks a normalized loudness level for one conversation audio stream.
///
/// Pull-based: `didReceive` runs on the audio thread and only holds the loudest
/// level seen. Reading drains it, which is also what paces the decay, so the
/// level keeps falling once a stream goes quiet and stops delivering buffers.
final class ConversationAudioLevelMonitor: ConversationAudioObserver, @unchecked Sendable {
    /// Fraction of the level kept per read: fast attack, slow release.
    private static let release: Float = 0.75

    private let lock = NSLock()
    private let scratchLock = NSLock()
    private var storedLevel: Float = 0
    /// Reused for Int16 conversion.
    private var scratch: [Float] = []

    /// The loudest level since the last read, leaving one release step behind.
    func sample() -> Float {
        lock.withLock {
            defer { storedLevel *= Self.release }
            return storedLevel
        }
    }

    func didReceive(_ buffer: AVAudioPCMBuffer) {
        guard let level = normalizedRMS(of: buffer) else { return }
        lock.withLock { storedLevel = max(level, storedLevel) }
    }

    func reset() {
        lock.withLock { storedLevel = 0 }
    }

    /// RMS of the first channel, mapped from the top 60 dB of headroom onto 0...1.
    private func normalizedRMS(of buffer: AVAudioPCMBuffer) -> Float? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let stride = buffer.format.isInterleaved ? vDSP_Stride(buffer.format.channelCount) : 1

        var rms: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            vDSP_rmsqv(channel, stride, &rms, vDSP_Length(frames))
        } else if let channel = buffer.int16ChannelData?[0] {
            scratchLock.withLock {
                // Grown, never reallocated per buffer: this is the audio thread.
                if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
                scratch.withUnsafeMutableBufferPointer { floats in
                    guard let samples = floats.baseAddress else { return }
                    vDSP_vflt16(channel, stride, samples, 1, vDSP_Length(frames))
                    var scale = 1 / Float(Int16.max)
                    vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(frames))
                    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frames))
                }
            }
        } else {
            return nil
        }

        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}
