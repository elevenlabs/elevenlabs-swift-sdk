import Foundation

/// An immutable, render-ready snapshot of **one** audio channel's levels at a
/// single instant — both an aggregated scalar (``average``) and the per-band
/// values (``bands``). Obtained from ``AudioLevelMonitor/current``.
///
/// One channel per value: the microphone (input) and agent (output) channels are
/// surfaced by separate monitors (``ConversationClient/inputLevels`` /
/// ``ConversationClient/outputLevels``), each vending its own `AudioLevels`.
public struct AudioLevels: Sendable, Equatable {
    /// Aggregated level across all bands, in `0...1` (smoothed, perceptual). The
    /// single-number view of ``bands``.
    public let average: Float

    /// Per-band levels in `0...1`, ordered low → high frequency. `count` matches
    /// the channel's configured band count
    /// (``AudioPipelineConfiguration/inputLevelBandCount`` or
    /// ``AudioPipelineConfiguration/outputLevelBandCount``). Empty when monitoring
    /// is disabled, the mic is muted, or the channel is silent/absent.
    public let bands: [Float]

    public init(average: Float, bands: [Float]) {
        self.average = average
        self.bands = bands
    }

    /// A silent channel: zero average, no bands.
    public static let silent = AudioLevels(average: 0, bands: [])
}
