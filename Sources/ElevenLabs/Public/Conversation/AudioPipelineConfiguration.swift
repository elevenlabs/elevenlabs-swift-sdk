import Foundation
import LiveKit

/// Event indicating the user is speaking while the microphone is muted.
public struct MutedSpeechEvent: Sendable {
    /// True when speech starts, false when speech ends.
    public let isSpeaking: Bool
    /// Audio level that triggered the event (0.0-1.0).
    public let audioLevel: Float
    
    public init(isSpeaking: Bool, audioLevel: Float) {
        self.isSpeaking = isSpeaking
        self.audioLevel = audioLevel
    }
}

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

    /// Observe LiveKit speech activity events while the microphone is muted.
    public var onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)?
    
    /// Called when local speech is detected while the microphone is muted.
    /// This uses local audio processing and works reliably with `.inputMixer` mode.
    /// Use this to show "You're speaking while muted" indicators.
    public var onMutedSpeech: (@Sendable (MutedSpeechEvent) -> Void)?
    
    /// RMS audio level (0.0-1.0) above which speech is detected. Default: 0.02 (~-34 dB).
    /// Increase to require louder speech, decrease for more sensitivity.
    public var mutedSpeechThreshold: Float?
    
    /// RMS audio level (0.0-1.0) below which silence is detected. Default: 0.01 (~-40 dB).
    /// The gap between this and `mutedSpeechThreshold` prevents rapid on/off flickering.
    public var mutedSilenceThreshold: Float?
    
    /// Consecutive silent frames required before speech ends. Default: 10 (~210ms).
    /// Increase to require longer pauses before "stopped speaking" fires.
    public var mutedSilenceFramesRequired: Int?

    public init(
        microphoneMuteMode: MicrophoneMuteMode? = .inputMixer,
        recordingAlwaysPrepared: Bool? = true,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil,
        onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)? = nil,
        onMutedSpeech: (@Sendable (MutedSpeechEvent) -> Void)? = nil,
        mutedSpeechThreshold: Float? = nil,
        mutedSilenceThreshold: Float? = nil,
        mutedSilenceFramesRequired: Int? = nil
    ) {
        self.microphoneMuteMode = microphoneMuteMode
        self.recordingAlwaysPrepared = recordingAlwaysPrepared
        self.voiceProcessingBypassed = voiceProcessingBypassed
        self.voiceProcessingAGCEnabled = voiceProcessingAGCEnabled
        self.onSpeechActivity = onSpeechActivity
        self.onMutedSpeech = onMutedSpeech
        self.mutedSpeechThreshold = mutedSpeechThreshold
        self.mutedSilenceThreshold = mutedSilenceThreshold
        self.mutedSilenceFramesRequired = mutedSilenceFramesRequired
    }

    public static let `default` = AudioPipelineConfiguration()
}

/// Retroactive Sendable conformance for LiveKit types.
///
/// These types from the LiveKit SDK are marked as @unchecked Sendable because:
/// - MicrophoneMuteMode: A simple enum with no mutable state, inherently thread-safe
/// - SpeechActivityEvent: A value type from LiveKit that is immutable once created
///
/// Note: These conformances should be reviewed when LiveKit SDK updates to Swift 6
/// with complete Sendable annotations.
extension MicrophoneMuteMode: @retroactive @unchecked Sendable {}
extension SpeechActivityEvent: @retroactive @unchecked Sendable {}
