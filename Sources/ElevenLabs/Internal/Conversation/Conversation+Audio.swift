import Foundation
import LiveKit

/// Audio-facing controls and taps for a `Conversation`:
/// - microphone (input) mute,
/// - agent (output) mute,
/// - raw PCM renderer registration, and
/// - the smoothed input/agent audio-level processors.
///
/// Split out of `Conversation` to keep that type focused on connection and
/// protocol logic. The backing stored state (tracks, processors, registries,
/// `audioManager`, `pendingMuteState`) lives on `Conversation` as `internal`.
@MainActor
extension Conversation {
    // MARK: - Live tracks
    //
    // Kept internal: consumers tap audio via `addAgentAudioRenderer(_:)` /
    // `addInputAudioRenderer(_:)` and control agent playback via
    // `setAgentMuted(_:)`, so the LiveKit track types never cross the public
    // boundary.

    private var inputTrack: LocalAudioTrack? {
        activeWebRTCConnectionManager?.inputTrack
    }

    private var agentAudioTrack: RemoteAudioTrack? {
        activeWebRTCConnectionManager?.agentAudioTrack
    }

    // MARK: - Microphone (input) mute
    //
    // Stops the user's audio from reaching the agent. Distinct from agent
    // (output) muting — see `setAgentMuted(_:)` below.

    /// Toggle the local microphone mute state.
    func toggleMicMute() async throws {
        try await setMicMuted(!isMicMuted)
    }

    /// Mute or unmute the local microphone. This is the single mute control.
    ///
    /// With the `.software` mute mode (see `MicrophoneMuteMode`) this toggles the
    /// software gate and keeps the capture track open; for every other mode it
    /// hardware-mutes the underlying capture track. When there is no live session
    /// to toggle (idle/ended/startup-failed) this is a best-effort no-op rather
    /// than an error, mirroring the agent-mute controls.
    func setMicMuted(_ muted: Bool) async throws {
        if !muted { isSpeakingWhileMuted = false }
        if let softwareMuteProcessor = audioManager?.softwareMuteProcessor {
            softwareMuteProcessor.setMuted(muted)
            isMicMuted = muted
            return
        }
        try await setHardwareMicMuted(muted)
    }

    /// Hardware-mute the underlying capture track. Internal implementation detail
    /// of ``setMicMuted(_:)`` for the non-software mute modes.
    func setHardwareMicMuted(_ muted: Bool) async throws {
        if state == .connected {
            guard let webRTCConnectionManager = activeWebRTCConnectionManager else {
                throw ConversationError.notConnected
            }
            do {
                try await webRTCConnectionManager.setMicrophoneMuted(muted)
                isMicMuted = muted
                pendingMuteState = nil
            } catch ConnectionManagerError.notConnected {
                throw ConversationError.notConnected
            } catch {
                throw ConversationError.microphoneToggleFailed(error)
            }
        } else if state.isConnecting {
            // Buffer the mute state to apply after connection completes
            pendingMuteState = muted
            isMicMuted = muted
        } else {
            // Not connected with nothing to apply to (idle/ended/startupFailed):
            // best-effort no-op rather than throwing, mirroring the non-throwing
            // agent-mute controls. There's no capture track to toggle here.
        }
    }

    // MARK: - Agent (output) mute
    //
    // Silences the agent's playback by setting the remote track's gain to zero —
    // a pure playback preference, independent of the mic and with no
    // hardware/permission coupling. `isAgentMuted` is the source of truth and is
    // re-applied whenever tracks change (see `refreshAudioLevelProcessors()`), so
    // it survives track swaps and applies once the agent track arrives.

    /// Toggle whether the agent's audio output (playback) is muted.
    func toggleAgentMute() {
        setAgentMuted(!isAgentMuted)
    }

    /// Mute or unmute the agent's audio output (playback).
    ///
    /// Sets the remote audio track's gain to `0` (muted) or `1` (unmuted). Safe
    /// to call at any time: if the agent track is not available yet, the
    /// preference is stored in ``isAgentMuted`` and applied automatically once
    /// the track arrives.
    func setAgentMuted(_ muted: Bool) {
        isAgentMuted = muted
        applyAgentMute()
    }

    /// Apply the current ``isAgentMuted`` preference to the live agent track.
    /// Idempotent and a no-op when no agent track is present.
    private func applyAgentMute() {
        agentAudioTrack?.volume = isAgentMuted ? 0 : 1
    }

    // MARK: - Audio renderers (raw PCM taps)
    //
    // These let advanced consumers observe the decoded PCM of the agent's output
    // or the local microphone — for visualization, recording, custom DSP, or to
    // derive their own metrics (frequency bands, a playout clock, etc). The SDK
    // keeps registered renderers attached across track swaps (connect/reconnect)
    // and attaches them automatically once the relevant track appears.

    /// Register a renderer to observe the **agent's** decoded output audio.
    ///
    /// Safe to call at any time: if the agent track is not available yet, the
    /// renderer is attached automatically once it arrives, and re-attached after
    /// reconnects. Re-adding the same instance is a no-op. Call
    /// ``removeAgentAudioRenderer(_:)`` to stop and release it.
    ///
    /// - Important: ``ConversationAudioRenderer/render(_:)`` is invoked on a
    ///   realtime audio thread, not the main actor.
    func addAgentAudioRenderer(_ renderer: any ConversationAudioRenderer) {
        agentRendererRegistry.add(renderer)
    }

    /// Unregister a previously-added agent audio renderer.
    func removeAgentAudioRenderer(_ renderer: any ConversationAudioRenderer) {
        agentRendererRegistry.remove(renderer)
    }

    /// Register a renderer to observe the **local microphone** input audio.
    ///
    /// Behaves like ``addAgentAudioRenderer(_:)`` but taps the capture track.
    /// Note that buffers continue to flow while the mic is muted unless capture
    /// is fully stopped; gate on ``isMicMuted`` if you only want unmuted audio.
    func addInputAudioRenderer(_ renderer: any ConversationAudioRenderer) {
        inputRendererRegistry.add(renderer)
    }

    /// Unregister a previously-added input audio renderer.
    func removeInputAudioRenderer(_ renderer: any ConversationAudioRenderer) {
        inputRendererRegistry.remove(renderer)
    }

    // MARK: - Audio levels

    /// Reconcile the level renderers with the currently-available tracks.
    /// Idempotent: safe to call repeatedly (on connect and on track changes).
    func refreshAudioLevelProcessors() {
        // Each channel's band count is independent; `0` disables that channel's
        // monitoring (no FFT) by passing a `nil` track, which tears down any
        // existing processor.
        let audio = config.audioConfiguration ?? .default
        let inputBands = audio.inputLevelBandCount
        let outputBands = audio.outputLevelBandCount

        syncLevelProcessor(
            track: inputBands > 0 ? inputTrack : nil,
            processor: &inputLevelProcessor,
            bandCount: inputBands,
            publish: { [weak self] average, bands in
                guard let self else { return }
                // Don't show input activity while the mic is muted.
                let muted = isMicMuted
                onInputLevels?(muted ? 0 : average, muted ? [] : bands)
            }
        )
        syncLevelProcessor(
            track: outputBands > 0 ? agentAudioTrack : nil,
            processor: &agentLevelProcessor,
            bandCount: outputBands,
            // Intentionally *not* gated on `isAgentMuted` (unlike the input side's
            // `isMicMuted` gate above): agent mute is a local *playback* gain
            // preference, so output levels deliberately keep reflecting the
            // agent's true decoded activity — a muted agent still drives the
            // visualizer.
            publish: { [weak self] average, bands in self?.onOutputLevels?(average, bands) }
        )
        // Reapply the agent-mute preference: track swaps (connect/reconnect)
        // hand back a fresh `RemoteAudioTrack` at unity gain, so the user's
        // chosen mute state must be re-applied to the new track.
        applyAgentMute()
        // Keep externally-registered renderers bound to the current tracks.
        agentRendererRegistry.attach(to: agentAudioTrack)
        inputRendererRegistry.attach(to: inputTrack)
    }

    /// Attach a fresh processor when a track appears or is swapped; detach and
    /// reset the level when the track goes away (or monitoring is disabled).
    private func syncLevelProcessor(
        track: AudioTrack?,
        processor: inout AudioLevelProcessor?,
        bandCount: Int,
        publish: @escaping (Float, [Float]) -> Void
    ) {
        if let track {
            guard processor?.track !== track else { return }
            processor?.detach()
            let next = AudioLevelProcessor(track: track, bandCount: bandCount)
            next.onChange = publish
            processor = next
        } else if processor != nil {
            processor?.detach()
            processor = nil
            publish(0, [])
        }
    }

    func teardownAudioLevelProcessors() {
        inputLevelProcessor?.detach()
        inputLevelProcessor = nil
        agentLevelProcessor?.detach()
        agentLevelProcessor = nil
        onInputLevels?(0, [])
        onOutputLevels?(0, [])
        // Detach (but keep registered) external renderers so they re-attach if
        // the conversation reconnects. Callers release them via remove*Renderer.
        agentRendererRegistry.attach(to: nil)
        inputRendererRegistry.attach(to: nil)
    }
}
