import Foundation

/// The set of network endpoints the SDK talks to.
///
/// Pass a custom value when you front ElevenLabs through a proxy/gateway, use a
/// regional/data-residency host, or point at a staging deployment. Defaults to
/// ``production``.
///
/// Two of the three endpoints (`textWebSocket`, `apiBase`) live on the same API
/// host, while `voiceWebSocket` (LiveKit signaling) is a separate host. The
/// conversation-token endpoint used for voice connections is derived from
/// `apiBase` by ``TokenService``. For the common "everything behind one API
/// host" case use ``apiBase(_:voiceWebSocket:)``, which derives the API-host
/// endpoints from a single base URL; use the memberwise initializer when you
/// need to override individual endpoints (e.g. a custom LiveKit host).
public struct ElevenLabsEndpoints: Sendable, Equatable {
    /// LiveKit signaling endpoint used for voice conversations.
    public var voiceWebSocket: URL
    /// WebSocket endpoint used for text-only conversations.
    public var textWebSocket: URL
    /// Base host for conversation-scoped REST endpoints (file upload/delete,
    /// post-call feedback).
    public var apiBase: URL

    /// Override individual endpoints. Any omitted endpoint falls back to its
    /// ``production`` value.
    public init(
        voiceWebSocket: URL = ElevenLabsEndpoints.production.voiceWebSocket,
        textWebSocket: URL = ElevenLabsEndpoints.production.textWebSocket,
        apiBase: URL = ElevenLabsEndpoints.production.apiBase
    ) {
        self.voiceWebSocket = voiceWebSocket
        self.textWebSocket = textWebSocket
        self.apiBase = apiBase
    }

    /// The default ElevenLabs production endpoints.
    public static let production = ElevenLabsEndpoints(
        voiceWebSocket: URL(string: "wss://livekit.rtc.elevenlabs.io")!,
        textWebSocket: URL(string: "wss://api.elevenlabs.io/v1/convai/conversation")!,
        apiBase: URL(string: "https://api.elevenlabs.io")!
    )

    /// Route the API-host endpoints (`textWebSocket`, `apiBase`) through a
    /// single base URL, deriving the text-WebSocket path from it. The text
    /// endpoint reuses `apiBaseURL`'s host with the scheme upgraded to
    /// `ws`/`wss`.
    ///
    /// - Parameters:
    ///   - apiBaseURL: Base URL of your API host, e.g. `https://my-proxy.example.com`.
    ///   - voiceWebSocket: LiveKit signaling host. Defaults to ``production``'s,
    ///     since LiveKit normally lives on a separate host from the API.
    public static func apiBase(
        _ apiBaseURL: URL,
        voiceWebSocket: URL = ElevenLabsEndpoints.production.voiceWebSocket
    ) -> ElevenLabsEndpoints {
        ElevenLabsEndpoints(
            voiceWebSocket: voiceWebSocket,
            textWebSocket: webSocketURL(from: apiBaseURL).appendingPathComponent("v1/convai/conversation"),
            apiBase: apiBaseURL
        )
    }

    /// Returns `url` with its scheme upgraded to the WebSocket equivalent
    /// (`http` → `ws`, `https`/unknown → `wss`); leaves `ws`/`wss` untouched.
    private static func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        switch components.scheme?.lowercased() {
        case "ws", "wss":
            break
        case "http":
            components.scheme = "ws"
        default:
            components.scheme = "wss"
        }
        return components.url ?? url
    }
}
