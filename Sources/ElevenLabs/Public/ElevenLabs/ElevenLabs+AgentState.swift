import Foundation

extension ElevenLabs {
    /// Agent state indicating what the agent is currently doing.
    public enum AgentState: Sendable, Equatable {
        /// Agent is listening to the user
        case listening
        /// Agent is speaking
        case speaking
        /// Agent is thinking (e.g. preparing a tool call)
        case thinking
    }
}
