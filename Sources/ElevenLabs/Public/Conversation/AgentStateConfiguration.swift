import Foundation

/// Configuration for event-based agent state management using VAD and client events.
/// Pass `nil` to use the default LiveKit-based behaviour.
public struct AgentStateConfiguration: Sendable {
    public var vadSpeakingThreshold: Double
    public var minSpeechDuration: TimeInterval
    public var minSilenceDuration: TimeInterval
    public var speakingToListeningDelay: TimeInterval

    public init(
        vadSpeakingThreshold: Double = 0.5,
        minSpeechDuration: TimeInterval = 0.15,
        minSilenceDuration: TimeInterval = 0.05,
        speakingToListeningDelay: TimeInterval = 0.5
    ) {
        self.vadSpeakingThreshold = vadSpeakingThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceDuration = minSilenceDuration
        self.speakingToListeningDelay = speakingToListeningDelay
    }

    public static let `default` = AgentStateConfiguration()
}
