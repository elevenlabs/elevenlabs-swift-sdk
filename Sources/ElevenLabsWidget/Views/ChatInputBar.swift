#if canImport(UIKit)
import SwiftUI

/// The bottom input bar: optional draft-attachment row, the text composer, and
/// the row of upload / mute / end / start / send controls, plus the "Powered by"
/// caption. Extracted from `ChatPopupView`. The host owns focus, the composer
/// autocorrect-reset token, and the file/photo picker presentation flags (the
/// pickers themselves are attached on the host), and supplies the
/// terms-gated start and end-conversation actions.
@available(iOS 16, macCatalyst 16, *)
struct ChatInputBar: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let widgetConfig: ChatWidgetConfig
    var isInputFocused: FocusState<Bool>.Binding
    @Binding var suppressComposerAutocorrect: Bool
    @Binding var isFileImporterPresented: Bool
    @Binding var isPhotosPickerPresented: Bool
    /// Runs the given start action, gated behind the Terms sheet when enabled.
    let requestStartConversation: (@escaping () -> Void) -> Void
    /// Ends the active conversation (animated by the host).
    let endConversation: () -> Void

    @ViewBuilder
    var body: some View {
        if shouldShowFooter {
            VStack(spacing: 0) {
                bottomBar
                Text(widgetConfig.strings.mainLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                    .padding(.bottom, 4)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if vm.draftAttachment != nil || vm.isUploadingAttachment {
                draftAttachmentRow
            }

            if vm.canShowTextInput {
                TextField(widgetConfig.strings.inputPlaceholder, text: $vm.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...2)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .focused(isInputFocused)
                    .autocorrectionDisabled(suppressComposerAutocorrect)
                    .onChange(of: vm.input) { _ in
                        guard !vm.input.isEmpty else { return }
                        vm.handleTypingActivity()
                    }
                    .onChange(of: vm.composerResetToken) { _ in
                        // Clearing `input` on send doesn't always redraw a
                        // multi-line TextField as empty when inline prediction /
                        // autocorrect was active (Apple bug FB13727682). Briefly
                        // toggling autocorrection forces the redraw WITHOUT
                        // changing the field's identity, so first responder (and
                        // the keyboard) is preserved for the next message.
                        suppressComposerAutocorrect = true
                        Task { @MainActor in suppressComposerAutocorrect = false }
                    }
            }

            HStack(spacing: 10) {
                if widgetConfig.enableFileUpload && vm.canUploadFile {
                    uploadMenuButton
                }

                if widgetConfig.enableMicMuteControl && vm.canToggleMicMute {
                    ChatMicButton(vm: vm, inputLevels: vm.inputLevels, diameter: 38, theme: widgetConfig.theme)
                }

                Spacer(minLength: 0)

                if vm.canEndConversation {
                    endConversationButton
                }

                if vm.canStartVoiceConversation {
                    voiceStartInputButton
                }

                if vm.canShowTextInput {
                    sendButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if vm.canShowTextInput {
                isInputFocused.wrappedValue = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var shouldShowFooter: Bool {
        vm.canShowTextInput || vm.canStartVoiceConversation || vm.canToggleMicMute || vm.canEndConversation
    }

    private var uploadMenuButton: some View {
        Menu {
            Button {
                isPhotosPickerPresented = true
            } label: {
                Label(widgetConfig.strings.photoLibrary, systemImage: "photo.on.rectangle")
            }
            Button {
                isFileImporterPresented = true
            } label: {
                Label(widgetConfig.strings.files, systemImage: "folder")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .strokeBorder(widgetConfig.theme.border, lineWidth: 1)
                    )
                PaperclipShape()
                    .fill(Color.black, style: FillStyle(eoFill: true))
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(widgetConfig.strings.addAttachmentLabel)
    }

    /// Pending attachment preview shown as its own row above the text input.
    @ViewBuilder
    private var draftAttachmentRow: some View {
        HStack(spacing: 8) {
            if let draft = vm.draftAttachment {
                if draft.fileExtension == "pdf" {
                    draftFilePill(draft)
                } else {
                    draftImageThumbnail(draft)
                }
            } else if vm.isUploadingAttachment {
                uploadingChip
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func draftImageThumbnail(_ draft: ChatWidgetViewModel.DraftAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            draftImageContent(draft)
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                vm.removeDraftAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(String(format: widgetConfig.strings.removeAttachmentFormat, draft.fileName))
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private func draftImageContent(_ draft: ChatWidgetViewModel.DraftAttachment) -> some View {
        if let data = draft.previewData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo.fill")
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }

    private func draftFilePill(_ draft: ChatWidgetViewModel.DraftAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(draft.fileName)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.primary)
            Button {
                vm.removeDraftAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: widgetConfig.strings.removeAttachmentFormat, draft.fileName))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.1))
                .overlay(Capsule(style: .continuous).strokeBorder(widgetConfig.theme.border, lineWidth: 1))
        )
    }

    private var uploadingChip: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(widgetConfig.strings.uploading)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
        .accessibilityLabel(widgetConfig.strings.uploadingFileLabel)
    }

    private var endConversationButton: some View {
        Button(action: endConversation) {
            ZStack {
                Circle()
                    .fill(widgetConfig.theme.destructiveTint)
                EndChatSquareShape()
                    .fill(widgetConfig.theme.destructive)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.mode == .text ? widgetConfig.strings.endChatLabel : widgetConfig.strings.endConversationLabel)
    }

    /// Start-call button shown in the input bar (left of Send) while a voice
    /// conversation hasn't started. Functionally mirrors the phone button that
    /// overlays the centered orb, but stays reachable when the orb is tucked
    /// into the header corner (e.g. keyboard up in landscape).
    private var voiceStartInputButton: some View {
        Button {
            requestStartConversation(vm.startVoiceConversation)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.clear)
                PhoneShape()
                    .fill(Color.black)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(widgetConfig.strings.startVoiceConversationLabel)
    }

    private var sendButton: some View {
        Button {
            if vm.hasActiveConversation {
                vm.sendText()
            } else {
                requestStartConversation(vm.sendText)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(vm.canSend ? Color.black : Color.secondary.opacity(0.65))
                PaperplaneShape()
                    .fill(Color.white)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSend)
        .accessibilityLabel(widgetConfig.strings.sendMessageLabel)
    }
}

#endif
