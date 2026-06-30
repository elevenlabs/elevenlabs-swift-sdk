import Foundation

/// The lifecycle of a conversation, from idle through connecting to a terminal
/// state. Surfaced via ``ConversationClient/state``.
///
/// The fine-grained connection/handshake progress is carried as the associated
/// ``StartupPhase`` of ``connecting``; callers that only care about the coarse
/// lifecycle can match `case .connecting` and ignore the phase.
public enum ConversationState: Equatable, Sendable {
    /// No active session. Also the resting state before the first `start`.
    case idle
    /// Connecting and running the startup handshake. The associated
    /// ``StartupPhase`` reports how far along the sequence has progressed.
    case connecting(phase: StartupPhase)
    /// Startup is complete; the conversation is live.
    case connected
    /// The conversation was connected and then stopped. See ``EndReason``.
    case ended(reason: EndReason)
    /// Startup failed before reaching ``connected``. The associated
    /// ``ConversationStartupFailure`` carries the underlying error. (Mid-session
    /// drops surface as ``ended`` with ``EndReason/remoteDisconnected``.)
    case startupFailed(ConversationStartupFailure)

    /// `true` unless the conversation is connecting or connected, i.e. the
    /// session is not occupying the transport and a new one may be started.
    public var isInactive: Bool {
        switch self {
        case .connecting, .connected: return false
        default: return true
        }
    }

    /// `true` while connecting (in any ``StartupPhase``).
    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// The phases a conversation moves through while connecting, before it is fully
/// live. Carried as the associated value of ``ConversationState/connecting(phase:)``.
///
/// The phases are transport-neutral and map onto both the voice (WebRTC/LiveKit)
/// and text (WebSocket) connection sequences:
///
/// - ``authorizing``: voice fetches a LiveKit token; text builds/validates the
///   WebSocket URL from `auth`.
/// - ``requestingMicPermission``: voice only — blocking on the user's response
///   to the microphone permission prompt. Only reported on a cold grant: the
///   prompt is requested concurrently with the token fetch (so it overlaps
///   network latency), and an already-decided permission is never surfaced as a
///   separate phase.
/// - ``connecting``: voice connects the room and enables the mic; text opens the
///   WebSocket and completes the handshake.
/// - ``waitingForAgent(timeout:)``: voice only — waiting for the agent to join
///   the room (the remote participant), bounded by the configured timeout.
/// - ``sendingInitData``: the `conversation_initiation_client_data` handshake
///   is being sent (both).
/// - ``waitingForInitData``: the handshake was sent; waiting for the server to
///   acknowledge with `conversation_initiation_metadata` (both). Startup is not
///   complete until this arrives.
public enum StartupPhase: Equatable, Sendable {
    case authorizing
    case requestingMicPermission
    case connecting
    case waitingForAgent(timeout: TimeInterval)
    case sendingInitData
    case waitingForInitData
}

public enum EndReason: Equatable, Sendable {
    case userEnded
    case remoteDisconnected
}

/// The reason a conversation failed to start, carried by
/// ``ConversationState/startupFailed(_:)`` and thrown out of `connect`.
public enum ConversationStartupFailure: Error, Sendable, Equatable {
    case token(ConversationError)
    case room(ConversationError)
    case microphone(ConversationError)
    case agentTimeout
    case conversationInit(ConversationError)

    /// The underlying ``ConversationError`` for this failure, surfaced to
    /// ``ConversationCallbacks/onError`` and rethrown from `connect`.
    public var error: ConversationError {
        switch self {
        case let .token(error),
             let .room(error),
             let .microphone(error),
             let .conversationInit(error):
            return error
        case .agentTimeout:
            return .agentTimeout
        }
    }
}
