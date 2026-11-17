import Foundation

/// Why a conversation ended. Passed to `onDisconnect` and carried by ``ConversationState/ended(reason:)``.
public enum EndReason: Equatable, Sendable {
    /// The app ended the conversation.
    case userEnded
    /// The agent ended the conversation: it called its `end_call` tool, left the room, or the server
    /// closed the connection normally.
    case agentEnded(Details = Details())
    /// An error ended the conversation: the connection failed, or the server ended it with an error.
    case error(Details = Details())

    /// What the SDK knows about how the remote side ended the conversation; `nil` for ``userEnded``.
    public var details: Details? {
        switch self {
        case .userEnded: nil
        case let .agentEnded(details), let .error(details): details
        }
    }

    /// What the SDK knows about how the remote side ended the conversation.
    public struct Details: Equatable, Sendable {
        /// A description of what ended the conversation, for logs. Not meant to be matched on.
        public var message: String?

        /// The close code the server sent when it closed the WebSocket of a text-only conversation.
        /// `nil` when the connection ended without one, and for voice conversations.
        public var closeCode: Int?

        /// The reason the server sent along with ``closeCode``; `nil` when it sent none.
        public var closeReason: String?

        /// The reason the server gave when it ended the room of a voice conversation. `nil` for
        /// text-only conversations, and when the room ended without one, such as when the agent left
        /// or the network dropped.
        public var roomDisconnectReason: RoomDisconnectReason?

        public init(
            message: String? = nil,
            closeCode: Int? = nil,
            closeReason: String? = nil,
            roomDisconnectReason: RoomDisconnectReason? = nil
        ) {
            self.message = message
            self.closeCode = closeCode
            self.closeReason = closeReason
            self.roomDisconnectReason = roomDisconnectReason
        }
    }

    /// The reason the server gave for ending a voice conversation's room, as the name of LiveKit's
    /// `DisconnectReason`.
    public struct RoomDisconnectReason: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The server confirmed that this client left the room.
        public static let clientInitiated = RoomDisconnectReason(rawValue: "CLIENT_INITIATED")
        /// Another participant joined the room with this participant's identity.
        public static let duplicateIdentity = RoomDisconnectReason(rawValue: "DUPLICATE_IDENTITY")
        /// The server shut down.
        public static let serverShutdown = RoomDisconnectReason(rawValue: "SERVER_SHUTDOWN")
        /// The server removed this participant from the room.
        public static let participantRemoved = RoomDisconnectReason(rawValue: "PARTICIPANT_REMOVED")
        /// The room was deleted.
        public static let roomDeleted = RoomDisconnectReason(rawValue: "ROOM_DELETED")
        /// The server and this client disagreed about the room's state.
        public static let stateMismatch = RoomDisconnectReason(rawValue: "STATE_MISMATCH")
        /// This client couldn't finish joining the room.
        public static let joinFailure = RoomDisconnectReason(rawValue: "JOIN_FAILURE")
        /// A reason LiveKit's Swift SDK doesn't name, such as `ROOM_CLOSED`.
        public static let unknown = RoomDisconnectReason(rawValue: "UNKNOWN_REASON")
    }
}
