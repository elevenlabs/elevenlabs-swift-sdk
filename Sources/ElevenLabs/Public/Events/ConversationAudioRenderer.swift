import AVFoundation

/// Observes the decoded PCM audio of a conversation stream before playback.
///
/// Attach a renderer via ``Conversation/addAgentAudioRenderer(_:)`` (the agent's
/// output) or ``Conversation/addInputAudioRenderer(_:)`` (the local microphone)
/// to tap the raw audio for visualization, recording, or custom DSP — e.g. to
/// derive frequency bands or a playout clock on your side.
///
/// - Important: ``render(_:)`` is invoked on a realtime audio thread, *not* the
///   main actor. Keep the work minimal and non-blocking, copy out any data you
///   need, and hop to your own queue/actor before touching UI state.
/// - Note: This is an observation hook only. Mutating the buffer does not affect
///   what is captured or played.
public protocol ConversationAudioRenderer: AnyObject, Sendable {
    /// Called with each decoded PCM buffer as it becomes available.
    func render(_ buffer: AVAudioPCMBuffer)
}
