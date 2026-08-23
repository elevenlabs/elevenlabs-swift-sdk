#if os(iOS)
import ElevenLabs
import Foundation

/// How the user can talk to the agent through ``ChatWidget``, and how each kind
/// of session authenticates.
///
/// Voice and text-only take different grants. Carrying ``ConversationAuth/Voice``
/// and ``ConversationAuth/TextOnly`` in the mode means a widget can never be
/// configured for a session it has no way to authenticate.
public enum WidgetConversationMode: Sendable {
    /// Typed messages only; the conversation runs without audio.
    case textOnly(ConversationAuth.TextOnly)
    /// A voice call with no composer.
    case voiceOnly(ConversationAuth.Voice, showsTranscript: Bool = true)
    /// A voice call the user can also type into.
    case voiceAndText(ConversationAuth.Voice)
    /// The user picks per session: the call button starts a voice call, typing
    /// the first message starts a text-only one.
    case voiceOrTextOnly(voice: ConversationAuth.Voice, textOnly: ConversationAuth.TextOnly)
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

    func start(
        _ kind: WidgetSessionKind,
        client: ConversationClient,
        config: ConversationConfig
    ) async throws {
        switch self {
        case let .textOnly(auth):
            _ = try await client.startTextOnlyConversation(auth, config: config)
        case let .voiceOnly(auth, _), let .voiceAndText(auth):
            _ = try await client.startVoiceConversation(auth, config: config)
        case let .voiceOrTextOnly(voice, textOnly):
            switch kind {
            case .voice:
                _ = try await client.startVoiceConversation(voice, config: config)
            case .textOnly:
                _ = try await client.startTextOnlyConversation(textOnly, config: config)
            }
        }
    }
}
#endif
