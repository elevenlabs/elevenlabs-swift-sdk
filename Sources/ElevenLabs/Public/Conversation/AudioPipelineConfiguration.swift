import Foundation

/// Configures microphone pipeline and voice activity reporting exposed by the SDK.
public struct AudioPipelineConfiguration: Sendable {
    /// Override the microphone mute strategy. Defaults to `.inputMixer` to match previous SDK behaviour.
    public var microphoneMuteMode: MicrophoneMuteMode?

    /// Keep the recording engine warm to avoid first-spoken-word latency. Defaults to `true`.
    public var recordingAlwaysPrepared: Bool?

    /// Bypass WebRTC voice processing (AEC/NS/VAD). Leave `nil` to preserve system defaults.
    public var voiceProcessingBypassed: Bool?

    /// Toggle Auto Gain Control. Leave `nil` to preserve system defaults.
    public var voiceProcessingAGCEnabled: Bool?

    public init(
        microphoneMuteMode: MicrophoneMuteMode? = .inputMixer,
        recordingAlwaysPrepared: Bool? = true,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil
    ) {
        self.microphoneMuteMode = microphoneMuteMode
        self.recordingAlwaysPrepared = recordingAlwaysPrepared
        self.voiceProcessingBypassed = voiceProcessingBypassed
        self.voiceProcessingAGCEnabled = voiceProcessingAGCEnabled
    }

    public static let `default` = AudioPipelineConfiguration()
}

/// Strategy used when muting the local microphone. Exactly one strategy is active
/// at a time.
public enum MicrophoneMuteMode: Sendable, Equatable {
    /// Mutes instantly by silencing the input mixer. The mic stays open and the
    /// audio session remains active. Recommended default.
    ///
    /// Use ``software(speechThreshold:)`` for silent muting with speech detection.
    case inputMixer

    /// Mutes by restarting the engine without mic input. Releases the mic, but
    /// mute/unmute is slower and speech detection is unavailable.
    case restart

    /// Mutes the voice-processing input. Fast, supports
    /// ``ConversationCallbacks/onSpeechDetectedWhileMuted``, and keeps the audio
    /// session active.
    case voiceProcessing

    /// Mutes in software by zeroing captured audio before it leaves the device.
    /// Supports ``ConversationCallbacks/onSpeechDetectedWhileMuted``.
    ///
    /// - Parameter speechThreshold: dB threshold for muted-speech detection.
    case software(speechThreshold: Float = -35)
}
