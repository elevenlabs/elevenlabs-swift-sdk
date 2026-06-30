import Foundation

/// Configures microphone pipeline and voice activity reporting exposed by the SDK.
public struct AudioPipelineConfiguration: Sendable {
    /// Override the microphone mute strategy. Defaults to `.inputMixer`.
    public var microphoneMuteMode: MicrophoneMuteMode?

    /// Bypass WebRTC voice processing (AEC/NS/VAD). Leave `nil` to preserve system defaults.
    public var voiceProcessingBypassed: Bool?

    /// Toggle Auto Gain Control. Leave `nil` to preserve system defaults.
    public var voiceProcessingAGCEnabled: Bool?

    /// Number of audio-level bands computed for the **microphone (input)** channel,
    /// surfaced via `ConversationClient.inputLevels`.
    ///
    /// - `0` disables monitoring for this channel — no FFT runs. Cheapest; use it
    ///   for headless / voice-only integrations that never show a mic meter.
    /// - `1` yields only the aggregate (``AudioLevels/average``).
    /// - Higher values (e.g. `16`) additionally populate ``AudioLevels/bands`` for
    ///   a multiband visualizer.
    ///
    /// The aggregate is always available whenever this is `> 0`. Defaults to `8`.
    /// The two channels are independent, so you can run a detailed agent orb while
    /// keeping the mic on a cheap single level (or off entirely).
    public var inputLevelBandCount: Int

    /// Number of audio-level bands computed for the **agent (output)** channel,
    /// surfaced via `ConversationClient.outputLevels`. See ``inputLevelBandCount``
    /// for the meaning of `0` / `1` / higher values. Defaults to `8`.
    public var outputLevelBandCount: Int

    public init(
        microphoneMuteMode: MicrophoneMuteMode? = .inputMixer,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil,
        inputLevelBandCount: Int = 8,
        outputLevelBandCount: Int = 8
    ) {
        self.microphoneMuteMode = microphoneMuteMode
        self.voiceProcessingBypassed = voiceProcessingBypassed
        self.voiceProcessingAGCEnabled = voiceProcessingAGCEnabled
        self.inputLevelBandCount = inputLevelBandCount
        self.outputLevelBandCount = outputLevelBandCount
    }

    public static let `default` = AudioPipelineConfiguration()
}

/// Strategy used when muting the local microphone. Exactly one strategy is active
/// at a time.
public enum MicrophoneMuteMode: Sendable, Equatable {
    /// Mutes instantly by silencing the audio engine's input mixer. The mic stays
    /// open and the audio session is untouched, so the iOS privacy indicator stays
    /// on and no sound effect plays. Fastest option; the recommended default.
    ///
    /// Note: because the mixer output is silenced *before* the system speech
    /// detector, `ConversationClient.isSpeakingWhileMuted` does not fire in this
    /// mode — use ``software(speechThreshold:)`` if you need silent muting *and*
    /// that detection.
    case inputMixer

    /// Mutes by deactivating the audio session and restarting the engine without
    /// mic input. The only mode that fully releases the mic — the iOS privacy
    /// indicator turns off and other apps can reclaim audio — but mute/unmute is
    /// slower and speaking-while-muted detection is unavailable.
    case restart

    /// Mutes the voice-processing input. Fast, and the system reports
    /// speaking-while-muted via `ConversationClient.isSpeakingWhileMuted`, but iOS
    /// plays a short sound effect on mute. The audio session is left active.
    case voiceProcessing

    /// Mutes in software: the capture track stays open but all captured audio is
    /// zeroed before it leaves the device. Silent (no sound effect) and reports
    /// speaking-while-muted via `ConversationClient.isSpeakingWhileMuted` using its
    /// own detector — the best of ``inputMixer`` and ``voiceProcessing``.
    ///
    /// - Parameter speechThreshold: dB level above which muted speech is detected.
    ///   Default-style value is `-35`; raise to require louder speech, lower for
    ///   more sensitivity.
    case software(speechThreshold: Float)
}
