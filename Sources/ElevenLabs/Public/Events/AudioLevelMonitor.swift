import Foundation

/// High-frequency level monitor for a **single** audio channel — the microphone
/// (input) or the agent (output) — kept as its own `ObservableObject`.
///
/// One channel per monitor on purpose: an `ObservableObject` notifies at object
/// granularity, so any `@Published` change re-renders *every* view observing it.
/// Splitting the channels means a mic meter (bound to
/// ``ConversationClient/inputLevels``) is never re-rendered by agent-output
/// updates, and vice versa — and neither churns a transcript bound to the client.
/// Each monitor is durable: the client owns one per channel for its lifetime and
/// feeds each session's levels in, so a view can bind once.
///
/// Two delivery models over the same data; pick per consumer:
/// - **Reactive scalar** — ``level`` is `@Published` (delta-gated): ideal for a
///   simple SwiftUI meter that wants one number.
/// - **Pull snapshot** — ``current`` is *not* published; sample it from a render
///   loop (orb / spectrum) for the per-band values without any SwiftUI churn.
@MainActor
public final class AudioLevelMonitor: ObservableObject {
    /// Channel level in `0...1` (smoothed, perceptual); forced to `0` while the mic
    /// is muted (input channel). Delta-gated reactive mirror of ``current``'s
    /// `average`.
    @Published public private(set) var level: Float = 0

    /// Latest render-ready snapshot — aggregate **and** per-band values. Updated at
    /// audio cadence but **not** `@Published`, so sampling it every frame (e.g. a
    /// Metal draw loop) never re-renders SwiftUI. Use this for a band visualizer;
    /// use ``level`` for a simple meter.
    public private(set) var current: AudioLevels = .silent

    public init() {}

    /// Smallest scalar change worth pushing through the `@Published` mirror;
    /// smaller deltas are imperceptible, so only the (cheap) snapshot updates.
    private static let scalarEpsilon: Float = 0.001

    /// Ingest one frame: refresh the pull snapshot, and forward the scalar to the
    /// `@Published` mirror only on a perceptible change.
    func set(average: Float, bands: [Float]) {
        current = AudioLevels(average: average, bands: bands)
        if abs(average - level) > Self.scalarEpsilon { level = average }
    }

    /// Reset to silence when a new session binds, so a prior conversation's levels
    /// don't linger until the first buffer arrives.
    func reset() {
        current = .silent
        level = 0
    }
}
