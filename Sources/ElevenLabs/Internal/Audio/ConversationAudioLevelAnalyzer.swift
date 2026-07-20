import Accelerate
@preconcurrency import AVFoundation

struct AudioSampleBatch: Sendable {
    let samples: [Float]
    let sampleRate: Float

    init?(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channelStride = buffer.format.isInterleaved
            ? Int(buffer.format.channelCount)
            : 1

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            samples = Self.copy(data[0], count: frameCount, stride: channelStride)
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            samples = Self.copy(data[0], count: frameCount, stride: channelStride)
                .map { Float($0) / Float(Int16.max) }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            samples = Self.copy(data[0], count: frameCount, stride: channelStride)
                .map { Float($0) / Float(Int32.max) }
        default:
            return nil
        }

        sampleRate = Float(buffer.format.sampleRate)
    }

    private static func copy<T>(
        _ source: UnsafeMutablePointer<T>,
        count: Int,
        stride: Int
    ) -> [T] {
        (0 ..< count).map { source[$0 * stride] }
    }
}

final class ConversationAudioLevelAnalyzer {
    private static let transformSize = 1024

    private let bandCount: Int
    private let transform: FrequencyBandTransform?
    private var pendingSamples: [Float] = []
    private var bands: [Float]

    init(bandCount: Int) {
        self.bandCount = bandCount
        transform = bandCount > 1
            ? FrequencyBandTransform(size: Self.transformSize, bandCount: bandCount)
            : nil
        bands = Array(repeating: 0, count: bandCount)
    }

    func process(_ batch: AudioSampleBatch) -> ConversationAudioLevels {
        guard let transform else {
            let average = Self.normalizedRMS(batch.samples)
            return ConversationAudioLevels(average: average, bands: [average])
        }

        pendingSamples.append(contentsOf: batch.samples)
        if pendingSamples.count >= Self.transformSize {
            bands = transform.process(
                Array(pendingSamples.suffix(Self.transformSize)),
                sampleRate: batch.sampleRate
            )
            pendingSamples.removeAll(keepingCapacity: true)
        }

        let average = bands.reduce(0, +) / Float(bands.count)
        return ConversationAudioLevels(average: average, bands: bands)
    }

    func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
        bands = Array(repeating: 0, count: bandCount)
    }

    private static func normalizedRMS(_ samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return normalizedDecibels(rms)
    }

    private static func normalizedDecibels(_ amplitude: Float) -> Float {
        let decibels = 20 * log10(max(amplitude, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

private final class FrequencyBandTransform {
    private let size: Int
    private let bandCount: Int
    private let setup: FFTSetup
    private let window: [Float]

    init(size: Int, bandCount: Int) {
        self.size = size
        self.bandCount = bandCount
        setup = vDSP_create_fftsetup(
            vDSP_Length(log2(Float(size))),
            FFTRadix(kFFTRadix2)
        )!

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func process(_ samples: [Float], sampleRate: Float) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        let halfSize = size / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(
                    realp: real.baseAddress!,
                    imagp: imaginary.baseAddress!
                )

                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfSize
                    ) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(
                    setup,
                    &split,
                    1,
                    vDSP_Length(log2(Float(size))),
                    FFTDirection(kFFTDirection_Forward)
                )
            }
        }

        var magnitudes = [Float](repeating: 0, count: halfSize)
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(
                    realp: real.baseAddress!,
                    imagp: imaginary.baseAddress!
                )
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        var scale = 2 / Float(size)
        vDSP_vsmul(
            magnitudes,
            1,
            &scale,
            &magnitudes,
            1,
            vDSP_Length(halfSize)
        )

        let binWidth = sampleRate / Float(size)
        let firstBin = max(1, Int(ceil(20 / binWidth)))
        let lastBin = min(halfSize - 1, Int(floor(min(8000, sampleRate / 2) / binWidth)))
        guard firstBin <= lastBin else {
            return Array(repeating: 0, count: bandCount)
        }

        let binCount = lastBin - firstBin + 1
        return (0 ..< bandCount).map { band in
            let start = firstBin + binCount * band / bandCount
            let end = max(start + 1, firstBin + binCount * (band + 1) / bandCount)
            let range = start ..< min(end, lastBin + 1)
            let meanSquare = range.reduce(Float.zero) {
                $0 + magnitudes[$1] * magnitudes[$1]
            } / Float(range.count)
            return min(max((20 * log10(max(sqrt(meanSquare), 0.000_001)) + 60) / 60, 0), 1)
        }
    }
}
