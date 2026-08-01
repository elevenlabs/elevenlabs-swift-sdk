#if os(iOS)
import ElevenLabs
import Foundation

/// How the user can talk to the agent through ``ChatWidget``, and how each kind
/// of session authenticates.
///
/// Voice runs over WebRTC and text-only over a WebSocket, and the two take
/// different credentials. Carrying the credentials in the mode means a widget
/// can never be configured for a session it has no way to authenticate.
public enum WidgetConversationMode: Sendable {
    /// Typed messages only; the conversation runs without audio.
    case textOnly(TextOnlyAuth)
    /// A voice call with no composer.
    case voiceOnly(VoiceAuth, showsTranscript: Bool = true)
    /// A voice call the user can also type into.
    case voiceAndText(VoiceAuth)
    /// The user picks per session: the call button starts a voice call, typing
    /// the first message starts a text-only one.
    case voiceOrTextOnly(voice: VoiceAuth, textOnly: TextOnlyAuth)

    public enum VoiceAuth: Sendable {
        case publicAgent(id: String, environment: String? = nil)
        /// Mints a conversation token from your backend for each call.
        case conversationToken(@Sendable () async throws -> String)
    }

    public enum TextOnlyAuth: Sendable {
        case publicAgent(id: String, environment: String? = nil)
        /// Mints a signed WebSocket URL from your backend for each session.
        case signedWebSocketURL(@Sendable () async throws -> String)
    }
}

/// The session ``ChatWidget`` is about to open.
enum WidgetSessionKind: Equatable {
    case voice
    case textOnly
}

extension WidgetConversationMode {
    var supportsVoice: Bool {
        if case .textOnly = self {
            false
        } else {
            true
        }
    }

    var supportsTextInput: Bool {
        if case .voiceOnly = self {
            false
        } else {
            true
        }
    }

    var showsTranscript: Bool {
        if case let .voiceOnly(_, showsTranscript) = self {
            showsTranscript
        } else { true }
    }

    /// The call button, and the host's `startConversation()`, open this kind of session.
    var requestedSessionKind: WidgetSessionKind {
        supportsVoice ? .voice : .textOnly
    }

    /// A message typed with nothing running opens this kind of session.
    var typedSessionKind: WidgetSessionKind {
        switch self {
        case .textOnly, .voiceOrTextOnly: .textOnly
        case .voiceOnly, .voiceAndText: .voice
        }
    }

    /// Minted per start, so tokens and signed URLs are never reused across sessions.
    func credentials(for kind: WidgetSessionKind) async throws -> ConversationCredentials {
        switch self {
        case let .textOnly(auth):
            try await auth.credentials()
        case let .voiceOnly(auth, _):
            try await auth.credentials()
        case let .voiceAndText(auth):
            try await auth.credentials()
        case let .voiceOrTextOnly(voice, textOnly):
            switch kind {
            case .voice: try await voice.credentials()
            case .textOnly: try await textOnly.credentials()
            }
        }
    }
}

extension WidgetConversationMode.VoiceAuth {
    func credentials() async throws -> ConversationCredentials {
        switch self {
        case let .publicAgent(id, environment):
            .publicAgent(id: id, environment: environment)
        case let .conversationToken(mint):
            try await .conversationToken(mint())
        }
    }
}

extension WidgetConversationMode.TextOnlyAuth {
    func credentials() async throws -> ConversationCredentials {
        switch self {
        case let .publicAgent(id, environment):
            .publicAgent(id: id, environment: environment)
        case let .signedWebSocketURL(mint):
            try await .signedWebSocketURL(mint())
        }
    }
}
#endif
