#if canImport(UIKit)
import SwiftUI

/// The drawer: header with the orb, transcript, composer.
@available(iOS 16, macCatalyst 16, *)
struct ChatPopupView: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let onClose: () -> Void

    @FocusState private var isInputFocused: Bool

    private var strings: ChatWidgetStrings {
        vm.widgetConfig.strings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.messages.isEmpty {
                Spacer(minLength: 0)
                orb(size: 128)
                Spacer(minLength: 0)
            } else {
                // A voice-only drawer has no composer to anchor it, so the orb
                // stays visible above the transcript.
                if !vm.canShowTextInput {
                    orb(size: 96).padding(.vertical, 12)
                }
                ChatTranscriptView(vm: vm)
            }
            ChatInputBar(vm: vm, isInputFocused: $isInputFocused)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            Text(strings.mainLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func orb(size: CGFloat) -> some View {
        ChatOrbView(levels: vm.audioLevels, state: vm.orbState, size: size, theme: vm.widgetConfig.theme)
    }

    private var header: some View {
        HStack(spacing: 12) {
            orb(size: 36)
            Text(strings.title)
                .font(.headline)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(strings.closeChatLabel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
#endif
