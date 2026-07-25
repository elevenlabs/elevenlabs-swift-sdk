#if os(iOS)
import SwiftUI

/// Composer plus the mic / start / end / send controls.
@available(iOS 16, macCatalyst 16, *)
struct ChatInputBar: View {
    @ObservedObject var vm: ChatWidgetViewModel
    var isInputFocused: FocusState<Bool>.Binding

    private var strings: ChatWidgetStrings {
        vm.widgetConfig.strings
    }

    private var theme: ChatWidgetTheme {
        vm.widgetConfig.theme
    }

    var body: some View {
        VStack(spacing: 10) {
            if vm.canShowTextInput {
                TextField(strings.inputPlaceholder, text: $vm.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 3)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .focused(isInputFocused)
                    .onSubmit(vm.send)
            }

            HStack(spacing: 10) {
                if vm.canToggleMicMute {
                    ChatMicButton(vm: vm, levels: vm.audioLevels, diameter: 38, theme: theme)
                }
                Spacer(minLength: 0)
                if vm.canEndConversation {
                    endConversationButton
                } else if vm.canStartVoiceConversation {
                    startConversationButton
                }
                if vm.canShowTextInput {
                    sendButton
                } else {
                    // Without a composer there is nothing to push the call
                    // controls away from, so they sit centered instead.
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { if vm.canShowTextInput { isInputFocused.wrappedValue = true } }
    }

    private var startConversationButton: some View {
        Button(action: vm.startConversation) {
            circle(fill: Color(.systemBackground), glyph: "phone.fill", tint: .primary)
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.startConversationLabel)
    }

    private var endConversationButton: some View {
        Button(action: vm.endConversation) {
            circle(fill: theme.destructiveTint, glyph: "phone.down.fill", tint: theme.destructive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.endConversationLabel)
    }

    private var sendButton: some View {
        Button(action: vm.send) {
            circle(
                fill: vm.canSend ? Color.black : Color.secondary.opacity(0.4),
                glyph: "paperplane.fill",
                tint: .white
            )
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSend)
        .accessibilityLabel(strings.sendMessageLabel)
    }

    private func circle(fill: Color, glyph: String, tint: Color) -> some View {
        Image(systemName: glyph)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 38, height: 38)
            .background(Circle().fill(fill))
    }
}
#endif
