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

    private static let interval: TimeInterval = 1.0 / 30
    private var timer: Timer?

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    deinit { timer?.invalidate() }

    private func start() {
        // Clears anything the audio thread wrote after the last stop, which would
        // otherwise surface as leftover loudness from the previous call.
        micMonitor.reset()
        agentMonitor.reset()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Common mode, so the levels keep updating while the transcript scrolls.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
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
