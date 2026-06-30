@preconcurrency import AVFoundation
import LiveKit

/// Taps a LiveKit ``AudioTrack`` and produces a smoothed, render-ready audio
/// level in `0...1`, suitable for driving a visualizer (e.g. the widget orb).
///
/// On each buffer it runs LiveKit's `AudioVisualizeProcessor` (FFT → normalized
/// frequency bands), smooths each band in place, then delivers both the smoothed
/// per-band values and a single aggregated perceptual level (mean → power curve →
/// small idle baseline) on the main actor via ``onChange``. Adapted from
/// ElevenLabs `components-swift` (Apache 2.0).
///
/// - Note: The resting baseline means an attached-but-silent track idles around
///   `0.05`, not `0`; ``detach()`` is what drives the level to `0`.
@MainActor
final class AudioLevelProcessor: AudioRenderer {
    /// Latest aggregated level in `0...1`.
    private(set) var level: Float = 0

    /// Invoked on the main actor for each processed buffer with the aggregated
    /// level and the smoothed per-band values (low → high frequency). `bands` is
    /// the processor's reused buffer; it's safe to store (copy-on-write protects
    /// the stored copy when the next buffer mutates it) but treat it as read-only.
    var onChange: ((Float, [Float]) -> Void)?

    /// The track currently being rendered. Exposed for identity comparison so
    /// callers can detect a track swap and re-attach.
    private(set) weak var track: AudioTrack?

    private let processor: AudioVisualizeProcessor
    /// Per-buffer smoothing coefficients in `0...1`, applied as an envelope
    /// follower (`new·coeff + old·(1−coeff)`): rising bands use `attack`, falling
    /// bands use `release`. The defaults are equal (symmetric); raise `attack`
    /// toward 1 for snappier onsets and lower `release` for a longer, smoother tail.
    private let attack: Float
    private let release: Float
    private var bands: [Float]

    /// Buffers flow from the realtime audio thread (``render(pcmBuffer:)``) to a
    /// single main-actor consumer through this stream. `bufferingNewest(1)` keeps
    /// the visualizer real-time, dropping stale frames if the consumer falls
    /// behind, and delivers them strictly in order so the order-sensitive
    /// envelope follower in ``apply(_:)`` never sees buffers out of sequence.
    private let bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var consumerTask: Task<Void, Never>?

    init(track: AudioTrack, bandCount: Int, attack: Float = 0.8, release: Float = 0.8) {
        self.track = track
        self.attack = attack
        self.release = release
        bands = Array(repeating: 0, count: bandCount)
        processor = AudioVisualizeProcessor(bandsCount: bandCount)

        // `AsyncStream.makeStream` is iOS 16+, so use the closure initializer to
        // stay within the package's iOS 15 deployment target.
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let stream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        bufferContinuation = continuation

        track.add(audioRenderer: self)

        // One long-lived consumer drains the stream on the main actor: FFT on the
        // `AudioVisualizeProcessor` actor (off-main), then smooth + publish here.
        consumerTask = Task { [weak self] in
            for await buffer in stream {
                guard let self else { return }
                guard let newBands = await self.processor.process(pcmBuffer: buffer) else { continue }
                self.apply(newBands)
            }
        }
    }

    deinit {
        bufferContinuation.finish()
        track?.remove(audioRenderer: self)
    }

    /// Detach from the track and stop emitting levels.
    func detach() {
        bufferContinuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
        track?.remove(audioRenderer: self)
        track = nil
        onChange = nil
    }

    // MARK: - AudioRenderer

    nonisolated func render(pcmBuffer: AVAudioPCMBuffer) {
        // The `AudioRenderer` contract doesn't guarantee `pcmBuffer`'s backing
        // store outlives this synchronous call, but the samples are read later on
        // another actor (`processor.process`). Deep-copy now so the consumer never
        // reads freed/overwritten memory — matching LiveKit's own recorder, which
        // also copies out of `render`. A single reusable buffer would be unsafe
        // here (the realtime producer and the async consumer overlap), and the
        // downstream FFT path allocates per frame anyway, so the copy is cheap.
        guard pcmBuffer.frameLength > 0 else { return }
        bufferContinuation.yield(pcmBuffer.copySegment())
    }

    // MARK: - Private

    private func apply(_ newBands: [Float]) {
        guard newBands.count == bands.count else { return }
        // Advance the per-band smoothing envelope (the persistent `bands` state):
        // rising bands use `attack`, falling bands use `release`.
        for i in bands.indices {
            let new = newBands[i]
            let coeff = new > bands[i] ? attack : release
            bands[i] = new * coeff + bands[i] * (1 - coeff)
        }

        level = Self.aggregate(bands)
        // Emit every buffer so pull consumers get the freshest frame; the reactive
        // scalar is delta-gated downstream in `AudioLevelMonitor`.
        onChange?(level, bands)
    }

    /// Collapse frequency bands into a single perceptual `0...1` level. Uniform
    /// band weights, so band ordering is irrelevant.
    private static func aggregate(_ bands: [Float]) -> Float {
        guard !bands.isEmpty else { return 0 }
        let mean = bands.reduce(0, +) / Float(bands.count)
        // Lower power makes quiet sounds more visible; amplify for responsiveness.
        let enhanced = pow(mean, 0.6) * 1.8
        // Small baseline keeps the visualizer subtly alive on quiet audio.
        return min(max(enhanced + 0.05, 0), 1)
    }
}
