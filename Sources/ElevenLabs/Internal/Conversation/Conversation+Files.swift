import Foundation

/// File attachments, multimodal messages, and post-call feedback.
///
/// The realtime send (`sendMultimodalMessage`) goes over the active data
/// channel; the file and feedback calls are conversation-scoped REST requests
/// (see `ConversationRESTClient`).
@MainActor
extension Conversation {
    /// Send a multimodal message — text and/or a previously uploaded file — to
    /// the agent over the active conversation.
    ///
    /// - Parameters:
    ///   - text: Optional message text. Whitespace-only text is treated as empty.
    ///   - fileId: Optional file id returned by `uploadConversationFile`.
    /// - Throws: `ConversationError.notConnected` if there is no active
    ///   conversation, or `.invalidMultimodalMessage` if both `text` and
    ///   `fileId` are empty.
    func sendMultimodalMessage(text: String?, fileId: String?) async throws {
        guard state == .connected else { throw ConversationError.notConnected }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = (trimmed?.isEmpty == false) ? trimmed : nil
        guard normalizedText != nil || fileId != nil else {
            throw ConversationError.invalidMultimodalMessage
        }

        try await publish(.multimodalMessage(MultimodalMessageEvent(text: normalizedText, fileId: fileId)))
        // Mirror text-message behaviour: append the local user bubble so the
        // transcript reflects the send immediately (callers correlate any
        // attachment preview to this user message).
        appendMessage(role: .user, content: normalizedText ?? "")
    }

    /// Upload a file to a conversation, returning its server-side `file_id` for
    /// use with `sendMultimodalMessage(text:fileId:)`.
    func uploadConversationFile(
        conversationId: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) async throws -> String {
        try await ConversationRESTClient(apiBase: config.endpoints.apiBase).uploadFile(
            conversationId: conversationId,
            fileName: fileName,
            mimeType: mimeType,
            fileData: fileData
        )
    }

    /// Delete a previously uploaded conversation file.
    func deleteConversationFile(conversationId: String, fileId: String) async throws {
        try await ConversationRESTClient(apiBase: config.endpoints.apiBase).deleteFile(conversationId: conversationId, fileId: fileId)
    }

    /// Submit post-call feedback (star rating and optional free-text comment)
    /// for a conversation via REST.
    ///
    /// This is distinct from the in-conversation `sendFeedback(_:eventId:)`
    /// like/dislike event: it targets a (typically ended) conversation by id.
    func submitPostCallFeedback(conversationId: String, rating: Int, comment: String?) async throws {
        try await ConversationRESTClient(apiBase: config.endpoints.apiBase).sendFeedback(
            conversationId: conversationId,
            rating: rating,
            comment: comment
        )
    }
}
