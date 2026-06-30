import Foundation

/// Lightweight REST client for the conversation HTTP endpoints that aren't part
/// of the realtime (LiveKit / WebSocket) data channel: the pre-connect room
/// token mint, file upload/delete, and post-call feedback.
///
/// The conversation-scoped endpoints are addressed by `conversationId` and are
/// called without an API key — the conversation id scopes the request. (Never
/// ship an ElevenLabs API key in a client app.)
struct ConversationRESTClient: Sendable {
    /// Path of the conversation-token endpoint, relative to ``apiBase``.
    private static let conversationTokenPath = "/v1/convai/conversation/token"

    private let apiBase: URL
    private let urlSession: URLSession

    init(
        apiBase: URL = ElevenLabsEndpoints.production.apiBase,
        urlSession: URLSession = .shared
    ) {
        self.apiBase = apiBase
        self.urlSession = urlSession
    }

    /// `GET /v1/convai/conversation/token?agent_id=…` → the participant token
    /// used to join the LiveKit room for a public agent.
    ///
    /// Distinct from the conversation-scoped endpoints below: this is the
    /// pre-connect handshake that mints a room token, so it has no
    /// `conversationId` and throws ``TokenError`` (which the WebRTC connection
    /// manager maps onto the user-facing `ConversationError`).
    ///
    /// - Parameter debugApiKey: DEBUG-only `xi-api-key` for local testing of
    ///   private agents. Always `nil` in release builds — never ship a key.
    func fetchConversationToken(
        agentId: String,
        environment: String?,
        debugApiKey: String?
    ) async throws -> String {
        guard var components = components(forPath: Self.conversationTokenPath) else {
            throw TokenError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "agent_id", value: agentId),
            URLQueryItem(name: "source", value: "swift_sdk"),
            URLQueryItem(name: "version", value: SDKVersion.version)
        ]
        if let environment {
            queryItems.append(URLQueryItem(name: "environment", value: environment))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw TokenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        #if DEBUG
        if let debugApiKey {
            request.setValue(debugApiKey, forHTTPHeaderField: "xi-api-key")
        }
        #endif

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TokenError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw TokenError.authenticationFailed
            }
            throw TokenError.httpError(statusCode: http.statusCode)
        }

        // ElevenLabs returns {"token": "..."}.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty
        else {
            throw TokenError.invalidTokenResponse
        }
        return token
    }

    /// `POST /v1/convai/conversations/{id}/files` (multipart) → `file_id`.
    func uploadFile(
        conversationId: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) async throws -> String {
        let url = try makeURL(path: "/v1/convai/conversations/\(encode(conversationId))/files")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType,
            boundary: boundary
        )

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, data: data, makeError: ConversationError.fileUploadFailed)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["file_id"] as? String, !fileId.isEmpty
        else {
            throw ConversationError.fileUploadFailed("Response did not include a file_id.")
        }
        return fileId
    }

    /// `DELETE /v1/convai/conversations/{id}/files/{fileId}`.
    func deleteFile(conversationId: String, fileId: String) async throws {
        let url = try makeURL(path: "/v1/convai/conversations/\(encode(conversationId))/files/\(encode(fileId))")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, data: data, makeError: ConversationError.fileDeleteFailed)
    }

    /// `POST /v1/convai/conversations/{id}/feedback` with `{ rating, comment? }`.
    func sendFeedback(conversationId: String, rating: Int, comment: String?) async throws {
        let url = try makeURL(path: "/v1/convai/conversations/\(encode(conversationId))/feedback")

        var payload: [String: Any] = ["rating": rating]
        if let comment, !comment.isEmpty {
            payload["comment"] = comment
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, data: data, makeError: ConversationError.feedbackSubmissionFailed)
    }

    // MARK: - Helpers

    /// Join `path` (a `/`-prefixed, already percent-encoded path such as
    /// `"/v1/convai/conversations/abc/files"`) onto `apiBase`, tolerating a
    /// trailing slash on the base so we never produce a `//` or a malformed URL.
    private func makeURL(path: String) throws -> URL {
        guard let url = components(forPath: path)?.url else {
            throw ConversationError.invalidURL
        }
        return url
    }

    /// Build `URLComponents` positioned at `apiBase` + `path` (a `/`-prefixed,
    /// already percent-encoded path), tolerating a trailing slash on the base so
    /// we never produce a `//`. Callers add query items / finalize to a `URL`
    /// and own the error domain (the conversation-scoped paths use
    /// `ConversationError`; the token mint uses `TokenError`).
    private func components(forPath path: String) -> URLComponents? {
        guard var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let base = components.percentEncodedPath
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        components.percentEncodedPath = trimmedBase + path
        return components
    }

    /// Percent-encode a single path segment (a `conversationId` / `fileId`).
    /// `.urlPathAllowed` permits `/`, so an id containing one would otherwise
    /// inject extra path segments (e.g. break out of the `{id}` slot); remove it
    /// so the value stays a single, opaque segment.
    private func encode(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    private static func validate(
        _ response: URLResponse,
        data: Data,
        makeError: (String) -> ConversationError
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw makeError("No HTTP response.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            throw makeError("HTTP \(http.statusCode)\(body.map { " — \($0)" } ?? "").")
        }
    }

    /// Strip characters that could break out of a quoted multipart header value
    /// (CR/LF header injection, or a stray `"` that would terminate the value).
    private static func sanitizeHeaderValue(_ value: String) -> String {
        value.filter { $0 != "\r" && $0 != "\n" && $0 != "\"" }
    }

    private static func multipartBody(
        fileData: Data,
        fileName: String,
        mimeType: String,
        boundary: String
    ) -> Data {
        let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(sanitizeHeaderValue(fileName))\"\r\n"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append(disposition.data(using: .utf8) ?? Data())
        body.append("Content-Type: \(sanitizeHeaderValue(mimeType))\r\n\r\n".data(using: .utf8) ?? Data())
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())
        return body
    }
}
