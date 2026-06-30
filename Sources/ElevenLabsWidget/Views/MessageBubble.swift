#if canImport(UIKit)
import SwiftUI
import UIKit
import ElevenLabs

/// Shared markdown helpers for the widget chrome (chat bubbles, terms sheet).
enum WidgetMarkdown {
    /// Parses inline markdown (bold, italic, strikethrough, inline code, links)
    /// while preserving whitespace/newlines. Block syntax (headings, lists,
    /// blockquotes, fenced code) is left as literal text.
    static func inlineAttributed(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let showsFeedbackControls: Bool
    var theme: ChatWidgetTheme = .default
    var strings: ChatWidgetStrings = .default
    var onFeedback: (FeedbackEvent.Score) -> Void = { _ in }
    var onMCPApproval: (Bool) -> Void = { _ in }

    init(
        message: ChatMessage,
        showsFeedbackControls: Bool = false,
        theme: ChatWidgetTheme = .default,
        strings: ChatWidgetStrings = .default,
        onFeedback: @escaping (FeedbackEvent.Score) -> Void = { _ in },
        onMCPApproval: @escaping (Bool) -> Void = { _ in }
    ) {
        self.message = message
        self.showsFeedbackControls = showsFeedbackControls
        self.theme = theme
        self.strings = strings
        self.onFeedback = onFeedback
        self.onMCPApproval = onMCPApproval
    }
    
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            
            if let attachment = message.attachment {
                attachmentMessageContent(attachment)
            } else {
                standardBubble
            }
            
            if message.role == .agent { Spacer(minLength: 32) }
        }
    }
    
    private var standardBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.kind == .error {
                Label(strings.errorLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(textColor.opacity(0.9))
            }
            if message.kind == .mcpApprovalRequest {
                Label(strings.mcpApprovalLabel, systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(textColor.opacity(0.9))
            }
            if isMarkdownMessage {
                MarkdownView(content: message.content)
                    .foregroundColor(textColor)
            } else {
                Text(messageAttributedText)
                    .font(.subheadline)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsFeedbackControls {
                feedbackControls
            }
            if message.kind == .mcpApprovalRequest {
                mcpApprovalControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    private var hasText: Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Agent text replies render full block markdown. Voice transcripts and user
    /// messages stay on the single-`Text` path (the former relies on raw
    /// character offsets for spoken-word highlighting).
    private var isMarkdownMessage: Bool {
        message.role == .agent && message.kind == .text
    }
    
    private func attachmentMessageContent(_ attachment: ChatMessage.Attachment) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            attachmentView(attachment)
            if hasText {
                Text(messageAttributedText)
                    .font(.subheadline)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
    
    @ViewBuilder
    private func attachmentView(_ attachment: ChatMessage.Attachment) -> some View {
        if attachment.isImage {
            attachmentImage(attachment)
        } else {
            attachmentFilePill(attachment)
        }
    }
    
    @ViewBuilder
    private func attachmentImage(_ attachment: ChatMessage.Attachment) -> some View {
        if let data = attachment.previewData, let image = UIImage(data: data) {
            // Compute an explicit frame that matches the image's aspect ratio so
            // the bitmap fills it exactly and the rounded clip lands on the image
            // (a flexible maxWidth/maxHeight frame can keep the full box size and
            // round transparent letterbox instead).
            let maxW: CGFloat = 150
            let maxH: CGFloat = 170
            let aspect = max(image.size.width, 1) / max(image.size.height, 1)
            let width = min(maxW, maxH * aspect)
            let height = width / aspect
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            attachmentFilePill(attachment)
        }
    }
    
    private func attachmentFilePill(_ attachment: ChatMessage.Attachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(attachment.fileName)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.1))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
        )
    }
    
    private var feedbackControls: some View {
        HStack(spacing: 10) {
            feedbackButton(score: .like, imageName: "hand.thumbsup")
            feedbackButton(score: .dislike, imageName: "hand.thumbsdown")
        }
        .padding(.top, 2)
    }
    
    private func feedbackButton(score: FeedbackEvent.Score, imageName: String) -> some View {
        let isSelected = message.feedbackScore == score
        return Button {
            onFeedback(score)
        } label: {
            Image(systemName: isSelected ? "\(imageName).fill" : imageName)
                .font(.caption)
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(score == .like ? strings.likeResponseLabel : strings.dislikeResponseLabel)
    }
    
    @ViewBuilder
    private var mcpApprovalControls: some View {
        if let status = message.mcpApprovalStatus {
            Label(
                status == .approved ? strings.approvedLabel : strings.rejectedLabel,
                systemImage: status == .approved ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundColor(status == .approved ? .green : .red)
            .padding(.top, 2)
        } else {
            HStack(spacing: 8) {
                Button {
                    onMCPApproval(true)
                } label: {
                    Label(strings.approveButton, systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button(role: .destructive) {
                    onMCPApproval(false)
                } label: {
                    Label(strings.rejectButton, systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }
    
    private var bubbleBackground: Color {
        switch message.kind {
        case .error:
            return Color.red.opacity(0.14)
        case .mcpApprovalRequest:
            return Color.blue.opacity(0.12)
        case .text, .voiceTranscript:
            return message.role == .user ? Color.black : Color.clear
        }
    }
    
    private var textColor: Color {
        if message.kind == .error {
            return .red
        }
        if message.kind == .mcpApprovalRequest {
            return .primary
        }
        return message.role == .user ? .white : .primary
    }
    
    private var messageAttributedText: AttributedString {
        // Agent text responses render markdown; voice transcripts and user
        // messages stay as raw text.
        if message.role == .agent, message.kind == .text {
            return markdownAttributedString(from: message.content)
        }
        return AttributedString(message.content)
    }
    
    private func markdownAttributedString(from content: String) -> AttributedString {
        WidgetMarkdown.inlineAttributed(content)
    }
}

#endif
