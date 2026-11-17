#if canImport(UIKit)
import Foundation

/// A richer agent state enum specifically for visualizer animations.
/// This enum preserves the full set of states needed for detailed visual feedback,
/// independent of the simplified SDK's `AgentState` enum.
enum VisualizerAgentState: Sendable, Equatable {
    /// Agent is connecting to the session
    case connecting
    /// Agent is initializing
    case initializing
    /// Agent is listening to user input
    case listening
    /// Agent is processing/thinking
    case thinking
    /// Agent is speaking
    case speaking
    /// Agent is disconnected
    case disconnected
    /// Unknown or unspecified state
    case unknown
}
#endif
