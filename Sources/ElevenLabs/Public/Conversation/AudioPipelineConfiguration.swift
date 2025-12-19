import Foundation
import LiveKit

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

    public init(
        microphoneMuteMode: MicrophoneMuteMode? = .inputMixer,
        recordingAlwaysPrepared: Bool? = true,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil,
        onSpeechActivity: (@Sendable (SpeechActivityEvent) -> Void)? = nil
    ) {
        self.microphoneMuteMode = microphoneMuteMode
        self.recordingAlwaysPrepared = recordingAlwaysPrepared
        self.voiceProcessingBypassed = voiceProcessingBypassed
        self.voiceProcessingAGCEnabled = voiceProcessingAGCEnabled
        self.onSpeechActivity = onSpeechActivity
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
