import Combine
import Foundation

/// Samples the mic and agent level monitors at a display-friendly rate.
///
/// The monitors are updated at PCM rate on the audio thread; publishing from
/// there would re-render SwiftUI thousands of times a second, so the levels are
/// polled on a timer while a conversation is live instead.
@MainActor
final class OrbAudioLevels: ObservableObject {
    @Published private(set) var input: Float = 0
    @Published private(set) var output: Float = 0

    let micMonitor = ConversationAudioLevelMonitor()
    let agentMonitor = ConversationAudioLevelMonitor()

    private static let intervalNanoseconds: UInt64 = 1_000_000_000 / 30
    private var samplingTask: Task<Void, Never>?

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    deinit { samplingTask?.cancel() }

    private func start() {
        // Clears anything the audio thread wrote after the last stop, which would
        // otherwise surface as leftover loudness from the previous call.
        micMonitor.reset()
        agentMonitor.reset()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.intervalNanoseconds)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                sample()
            }
        }
    }

    private func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        micMonitor.reset()
        agentMonitor.reset()
        input = 0
        output = 0
    }

    /// Only publishes on change, so a silent conversation doesn't redraw the orb.
    private func sample() {
        let mic = micMonitor.sample()
        let agent = agentMonitor.sample()
        if mic != input { input = mic }
        if agent != output { output = agent }
    }
}
