@preconcurrency import AVFoundation
import LiveKit

/// Bridges a user-supplied ``ConversationAudioObserver`` to LiveKit's
/// `AudioRenderer`, keeping the LiveKit type fully internal. Holds the user
/// observer alive for as long as it is registered.
private final class LiveKitAudioRendererAdapter: AudioRenderer, @unchecked Sendable {
    private let observer: any ConversationAudioObserver

    init(_ observer: any ConversationAudioObserver) {
        self.observer = observer
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        observer.didReceive(pcmBuffer)
    }
}

/// Tracks externally registered audio observers for a single stream (agent
/// output or mic input) and keeps them attached across track swaps.
///
/// All mutating entry points are `@MainActor`; adapters forward buffers on the
/// audio callback path without touching this registry's state.
@MainActor
final class AudioObserverRegistry {
    private var adapters: [ObjectIdentifier: LiveKitAudioRendererAdapter] = [:]
    private weak var attachedTrack: (any AudioTrackProtocol)?

    /// Number of currently registered observers.
    var registeredCount: Int {
        adapters.count
    }

    /// Register an observer, attaching it to the current track if one is present.
    /// Re-adding the same observer instance is a no-op.
    func add(_ observer: any ConversationAudioObserver) {
        let key = ObjectIdentifier(observer)
        guard adapters[key] == nil else { return }
        let adapter = LiveKitAudioRendererAdapter(observer)
        adapters[key] = adapter
        attachedTrack?.add(audioRenderer: adapter)
    }

    /// Unregister an observer, detaching it from the current track.
    func remove(_ observer: any ConversationAudioObserver) {
        let key = ObjectIdentifier(observer)
        guard let adapter = adapters.removeValue(forKey: key) else { return }
        attachedTrack?.remove(audioRenderer: adapter)
    }

    /// Point the registry at a (possibly new or `nil`) track. Detaches every
    /// adapter from the previous track and attaches them to the new one, so
    /// registered observers survive track swaps. Idempotent for the same track.
    func attach(to track: (any AudioTrackProtocol)?) {
        guard track !== attachedTrack else { return }
        if let attachedTrack {
            for adapter in adapters.values {
                attachedTrack.remove(audioRenderer: adapter)
            }
        }
        attachedTrack = track
        if let track {
            for adapter in adapters.values {
                track.add(audioRenderer: adapter)
            }
        }
    }

    /// Detach from any track and drop all registrations. Used when a single-use
    /// session ends; durable re-registration is owned by `ConversationClient`.
    func reset() {
        attach(to: nil)
        adapters.removeAll()
    }
}
