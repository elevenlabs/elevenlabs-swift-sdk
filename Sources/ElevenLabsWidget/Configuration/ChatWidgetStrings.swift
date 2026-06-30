#if canImport(UIKit)
import Foundation

/// User-facing strings shown by the chat widget. Pass a custom instance via
/// `ChatWidgetConfig.strings` to localize or rebrand the widget.
///
/// Every literal the widget renders or exposes to assistive technologies lives
/// here, so the whole UI can be localized from one place. A handful of fields
/// are format strings (their names end in `Format`); substitute the documented
/// placeholder with `String(format:_:)`.
///
/// Terms & conditions copy is configured separately via ``ChatWidgetTerms``.
///
/// ```swift
/// var strings = ChatWidgetStrings()
/// strings.inputPlaceholder = "Ask anything…"
/// let config = ChatWidgetConfig(conversationMode: .voiceAndText, strings: strings)
/// ```
public struct ChatWidgetStrings: Equatable {
    // MARK: - Header & chrome

    /// Title shown in the popup header.
    public var title: String

    /// Attribution caption under the input bar. Web parity: `main_label`.
    public var mainLabel: String

    /// Placeholder in the message composer. Web parity: `input_placeholder`.
    public var inputPlaceholder: String

    /// Notice shown when a voice configuration hides the text transcript.
    public var messagesHiddenNotice: String

    /// Debug caption showing the conversation id. `%@` is the id.
    public var conversationIdFormat: String

    /// Label of the in-call settings button.
    public var settings: String

    // MARK: - Conversation ended

    /// Shown when the user ended the conversation.
    /// Web parity: `user_ended_conversation`.
    public var userEndedConversation: String

    /// Shown when the agent / server ended the conversation.
    /// Web parity: `agent_ended_conversation`.
    public var agentEndedConversation: String

    // MARK: - Composer & attachments

    /// "Photo Library" entry in the attachment menu.
    public var photoLibrary: String

    /// "Files" entry in the attachment menu.
    public var files: String

    /// Status shown while an attachment uploads.
    public var uploading: String

    // MARK: - Feedback

    /// Headline of the post-call feedback sheet. Web parity: `initiate_feedback`.
    public var initiateFeedback: String

    /// Sub-headline / question on the feedback sheet.
    public var feedbackQuestion: String

    /// Placeholder in the feedback comment field.
    /// Web parity: `follow_up_feedback_placeholder`.
    public var followUpFeedbackPlaceholder: String

    /// Submit button on the feedback sheet. Web parity: `submit`.
    public var submit: String

    // MARK: - Message bubbles

    /// Label on an error message bubble.
    public var errorLabel: String

    /// Label on an MCP tool-approval bubble.
    public var mcpApprovalLabel: String

    /// "Approve" button on an MCP tool-approval bubble.
    public var approveButton: String

    /// "Reject" button on an MCP tool-approval bubble.
    public var rejectButton: String

    /// Status shown after an MCP tool request is approved.
    public var approvedLabel: String

    /// Status shown after an MCP tool request is rejected.
    public var rejectedLabel: String

    /// MCP request bubble headline. `%@` is the tool name.
    public var mcpToolRequestFormat: String

    /// MCP request bubble parameter line. `%@` is the parameter list.
    public var mcpParametersFormat: String

    /// MCP request bubble timeout line. `%@` is the seconds remaining.
    public var mcpApprovalExpiresFormat: String

    // MARK: - Errors & banners

    /// Banner shown when the conversation fails to start.
    public var startConversationFailed: String

    /// Banner shown when microphone access is denied (deep-links to Settings).
    public var microphoneAccessOff: String

    /// Synthetic message shown when sending a message fails.
    public var sendMessageFailed: String

    /// Synthetic message shown when sending an MCP approval response fails.
    public var mcpApprovalResponseFailed: String

    /// Banner shown when an unsupported file type is picked.
    public var unsupportedFileType: String

    /// Banner shown when the selected file can't be read.
    public var fileReadFailed: String

    /// Banner shown when a file exceeds the size limit. `%@` is the limit.
    public var fileTooLargeFormat: String

    /// Banner shown when a file upload fails.
    public var fileUploadFailed: String

    /// Generic fallback error message.
    public var genericError: String

    // MARK: - Accessibility labels

    /// VoiceOver label on the floating launcher button.
    public var openChatLabel: String

    /// VoiceOver label on the drawer handle when collapsed.
    public var expandChatLabel: String

    /// VoiceOver label on the drawer handle when expanded.
    public var collapseChatLabel: String

    /// VoiceOver label on the add-attachment button.
    public var addAttachmentLabel: String

    /// VoiceOver label on the remove-attachment button. `%@` is the file name.
    public var removeAttachmentFormat: String

    /// VoiceOver label on the uploading-attachment indicator.
    public var uploadingFileLabel: String

    /// VoiceOver label on the send button.
    public var sendMessageLabel: String

    /// VoiceOver label on the start-voice button.
    public var startVoiceConversationLabel: String

    /// VoiceOver label on the end button in text mode.
    public var endChatLabel: String

    /// VoiceOver label on the end button in voice mode.
    public var endConversationLabel: String

    /// VoiceOver label on the open-Settings banner button.
    public var openSettingsLabel: String

    /// VoiceOver label on the dismiss-banner button.
    public var dismissLabel: String

    /// VoiceOver label on the mic button when unmuted.
    public var muteMicrophoneLabel: String

    /// VoiceOver label on the mic button when muted.
    public var unmuteMicrophoneLabel: String

    /// VoiceOver label on a like-response button.
    public var likeResponseLabel: String

    /// VoiceOver label on a dislike-response button.
    public var dislikeResponseLabel: String

    /// Singular unit used in the feedback star VoiceOver label (e.g. "1 star").
    public var ratingStarUnitSingular: String

    /// Plural unit used in the feedback star VoiceOver label (e.g. "5 stars").
    public var ratingStarUnitPlural: String

    public init(
        title: String = "Chat",
        mainLabel: String = "Powered by ElevenLabs",
        inputPlaceholder: String = "Type a message…",
        messagesHiddenNotice: String = "Messages are hidden for this voice configuration.",
        conversationIdFormat: String = "ID:%@",
        settings: String = "Settings",
        userEndedConversation: String = "You ended the conversation",
        agentEndedConversation: String = "Conversation ended",
        photoLibrary: String = "Photo Library",
        files: String = "Files",
        uploading: String = "Uploading…",
        initiateFeedback: String = "How was this call?",
        feedbackQuestion: String = "Did this conversation help you with what you needed?",
        followUpFeedbackPlaceholder: String = "Tell us more (optional)",
        submit: String = "Submit",
        errorLabel: String = "Error",
        mcpApprovalLabel: String = "MCP tool approval",
        approveButton: String = "Approve",
        rejectButton: String = "Reject",
        approvedLabel: String = "Approved",
        rejectedLabel: String = "Rejected",
        mcpToolRequestFormat: String = "MCP tool request: %@",
        mcpParametersFormat: String = "Parameters: %@",
        mcpApprovalExpiresFormat: String = "Approval expires in %@s.",
        startConversationFailed: String = "Couldn't start the conversation. Please try again.",
        microphoneAccessOff: String = "Microphone access is off. Enable it in Settings.",
        sendMessageFailed: String = "Failed to send message. Please try again.",
        mcpApprovalResponseFailed: String = "Failed to send MCP approval response. Please try again.",
        unsupportedFileType: String = "Unsupported file type. Use PNG, JPEG, GIF, WEBP, or PDF.",
        fileReadFailed: String = "Could not read the selected file.",
        fileTooLargeFormat: String = "File is too large. Max size is %@.",
        fileUploadFailed: String = "Failed to upload file. Please try again.",
        genericError: String = "An error occurred.",
        openChatLabel: String = "Open chat",
        expandChatLabel: String = "Expand chat",
        collapseChatLabel: String = "Collapse chat",
        addAttachmentLabel: String = "Add attachment",
        removeAttachmentFormat: String = "Remove %@",
        uploadingFileLabel: String = "Uploading file",
        sendMessageLabel: String = "Send message",
        startVoiceConversationLabel: String = "Start voice conversation",
        endChatLabel: String = "End chat",
        endConversationLabel: String = "End conversation",
        openSettingsLabel: String = "Open Settings",
        dismissLabel: String = "Dismiss",
        muteMicrophoneLabel: String = "Mute microphone",
        unmuteMicrophoneLabel: String = "Unmute microphone",
        likeResponseLabel: String = "Like response",
        dislikeResponseLabel: String = "Dislike response",
        ratingStarUnitSingular: String = "star",
        ratingStarUnitPlural: String = "stars"
    ) {
        self.title = title
        self.mainLabel = mainLabel
        self.inputPlaceholder = inputPlaceholder
        self.messagesHiddenNotice = messagesHiddenNotice
        self.conversationIdFormat = conversationIdFormat
        self.settings = settings
        self.userEndedConversation = userEndedConversation
        self.agentEndedConversation = agentEndedConversation
        self.photoLibrary = photoLibrary
        self.files = files
        self.uploading = uploading
        self.initiateFeedback = initiateFeedback
        self.feedbackQuestion = feedbackQuestion
        self.followUpFeedbackPlaceholder = followUpFeedbackPlaceholder
        self.submit = submit
        self.errorLabel = errorLabel
        self.mcpApprovalLabel = mcpApprovalLabel
        self.approveButton = approveButton
        self.rejectButton = rejectButton
        self.approvedLabel = approvedLabel
        self.rejectedLabel = rejectedLabel
        self.mcpToolRequestFormat = mcpToolRequestFormat
        self.mcpParametersFormat = mcpParametersFormat
        self.mcpApprovalExpiresFormat = mcpApprovalExpiresFormat
        self.startConversationFailed = startConversationFailed
        self.microphoneAccessOff = microphoneAccessOff
        self.sendMessageFailed = sendMessageFailed
        self.mcpApprovalResponseFailed = mcpApprovalResponseFailed
        self.unsupportedFileType = unsupportedFileType
        self.fileReadFailed = fileReadFailed
        self.fileTooLargeFormat = fileTooLargeFormat
        self.fileUploadFailed = fileUploadFailed
        self.genericError = genericError
        self.openChatLabel = openChatLabel
        self.expandChatLabel = expandChatLabel
        self.collapseChatLabel = collapseChatLabel
        self.addAttachmentLabel = addAttachmentLabel
        self.removeAttachmentFormat = removeAttachmentFormat
        self.uploadingFileLabel = uploadingFileLabel
        self.sendMessageLabel = sendMessageLabel
        self.startVoiceConversationLabel = startVoiceConversationLabel
        self.endChatLabel = endChatLabel
        self.endConversationLabel = endConversationLabel
        self.openSettingsLabel = openSettingsLabel
        self.dismissLabel = dismissLabel
        self.muteMicrophoneLabel = muteMicrophoneLabel
        self.unmuteMicrophoneLabel = unmuteMicrophoneLabel
        self.likeResponseLabel = likeResponseLabel
        self.dislikeResponseLabel = dislikeResponseLabel
        self.ratingStarUnitSingular = ratingStarUnitSingular
        self.ratingStarUnitPlural = ratingStarUnitPlural
    }

    public static let `default` = ChatWidgetStrings()
}

#endif
