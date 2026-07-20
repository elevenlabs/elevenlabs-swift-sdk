@preconcurrency import AVFoundation
import Dispatch
import Foundation

/// A thread-safe snapshot of conversation audio levels in `0...1`.
public struct ConversationAudioLevels: Equatable, Sendable {
    /// Overall audio level.
    public let average: Float

    /// Frequency-band levels ordered from low to high frequency.
    public let bands: [Float]

    /// A snapshot with no measured audio.
    public static let silent = ConversationAudioLevels(average: 0, bands: [])
}

/// Computes pull-based audio levels without publishing on the main actor.
///
/// Register the monitor as a mic or agent audio observer, then read ``current``
/// at the cadence needed by your UI or other consumer.
///
/// Use a separate monitor for each audio stream.
public final class ConversationAudioLevelMonitor: ConversationAudioObserver, @unchecked Sendable {
    /// The latest completed level snapshot.
    public var current: ConversationAudioLevels {
        lock.lock()
        defer { lock.unlock() }
        return state.current
    }

    private struct State {
        var current: ConversationAudioLevels
        var isProcessing = false
        var generation = 0
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "io.elevenlabs.conversation-audio-level-monitor",
        qos: .userInteractive
    )
    private let analyzer: ConversationAudioLevelAnalyzer
    private var state: State

    /// Creates a monitor with the requested number of frequency bands.
    ///
    /// A `bandCount` of `1` returns the overall level as the sole band.
    public init(bandCount: Int = 1) {
        precondition(bandCount > 0, "bandCount must be greater than zero")
        analyzer = ConversationAudioLevelAnalyzer(bandCount: bandCount)
        state = State(current: .silent)
    }

    public func didReceive(_ buffer: AVAudioPCMBuffer) {
        guard lock.try() else { return }
        guard !state.isProcessing else {
            lock.unlock()
            return
        }
        state.isProcessing = true
        let generation = state.generation
        lock.unlock()

        guard let batch = AudioSampleBatch(buffer) else {
            finishProcessing(generation: generation, levels: nil)
            return
        }

        queue.async { [self] in
            finishProcessing(
                generation: generation,
                levels: analyzer.process(batch)
            )
        }
    }

    /// Clears the latest snapshot and any buffered samples.
    public func reset() {
        lock.lock()
        state.current = .silent
        state.generation += 1
        lock.unlock()

        queue.async { [analyzer] in
            analyzer.reset()
        }
    }

    private func finishProcessing(generation: Int, levels: ConversationAudioLevels?) {
        lock.lock()
        defer { lock.unlock() }
        if generation == state.generation, let levels {
            state.current = levels
        }
        state.isProcessing = false
    }
}
