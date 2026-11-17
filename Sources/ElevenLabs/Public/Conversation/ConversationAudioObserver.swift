import AVFoundation

/// Observes decoded PCM audio from a conversation stream.
///
/// Attach an observer via ``ConversationClient/addAgentAudioObserver(_:)`` (agent
/// output) or ``ConversationClient/addMicAudioObserver(_:)`` (local microphone)
/// to receive raw audio for visualization, recording, or custom analysis.
///
/// - Important: ``didReceive(_:)`` is called synchronously on a time-critical
///   audio callback path. The SDK does not dispatch it to the main actor. Keep
///   the work minimal and non-blocking; copy any samples you need during the
///   call, then hop to your own queue or actor before touching UI or doing
///   heavy processing.
/// - Note: The buffer is borrowed and must be treated as read-only. Mutating it
///   is unsupported and must not be relied on to affect capture or playback.
public protocol ConversationAudioObserver: AnyObject, Sendable {
    /// Called with each decoded PCM buffer as it becomes available.
    func didReceive(_ buffer: AVAudioPCMBuffer)
}
