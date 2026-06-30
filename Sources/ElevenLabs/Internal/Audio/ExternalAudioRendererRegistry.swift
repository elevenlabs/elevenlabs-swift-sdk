@preconcurrency import AVFoundation
import LiveKit

/// Bridges a user-supplied ``ConversationAudioRenderer`` to LiveKit's
/// `AudioRenderer`, keeping the LiveKit type fully internal. Holds the user
/// renderer alive for as long as it is registered.
private final class LiveKitAudioRendererAdapter: AudioRenderer, @unchecked Sendable {
    private let renderer: any ConversationAudioRenderer

    init(_ renderer: any ConversationAudioRenderer) {
        self.renderer = renderer
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        renderer.render(pcmBuffer)
    }
}

/// Tracks the externally-registered audio renderers for a single audio stream
/// (the agent track or the mic track) and keeps them attached across track
/// swaps (connect/reconnect).
///
/// All mutating entry points are `@MainActor`; the adapters forward buffers on
/// LiveKit's realtime audio thread without touching this registry's state.
@MainActor
final class ExternalAudioRendererRegistry {
    private var adapters: [ObjectIdentifier: LiveKitAudioRendererAdapter] = [:]
    private weak var attachedTrack: AudioTrack?

    /// Register a renderer, attaching it to the current track if one is present.
    /// Re-adding the same renderer instance is a no-op.
    func add(_ renderer: any ConversationAudioRenderer) {
        let key = ObjectIdentifier(renderer)
        guard adapters[key] == nil else { return }
        let adapter = LiveKitAudioRendererAdapter(renderer)
        adapters[key] = adapter
        attachedTrack?.add(audioRenderer: adapter)
    }

    /// Unregister a renderer, detaching it from the current track.
    func remove(_ renderer: any ConversationAudioRenderer) {
        let key = ObjectIdentifier(renderer)
        guard let adapter = adapters.removeValue(forKey: key) else { return }
        attachedTrack?.remove(audioRenderer: adapter)
    }

    /// Point the registry at a (possibly new or `nil`) track. Detaches every
    /// adapter from the previous track and attaches them to the new one, so the
    /// caller's renderers survive track swaps. Idempotent for the same track.
    func attach(to track: AudioTrack?) {
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
}
