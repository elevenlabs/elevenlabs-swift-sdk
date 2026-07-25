#if os(iOS)
import SwiftUI

/// The drawer: grabber, banner, header with the orb, transcript, composer.
@available(iOS 16, macCatalyst 16, *)
struct ChatPopupView: View {
    @ObservedObject var vm: ChatWidgetViewModel
    @Binding var detent: ChatDrawerDetent
    let onClose: () -> Void

    @FocusState private var isInputFocused: Bool
    @State private var dragOffset: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private static let cornerRadius: CGFloat = 32
    private static let detentSpring = Animation.spring(response: 0.42, dampingFraction: 0.85)

    private var strings: ChatWidgetStrings {
        vm.widgetConfig.strings
    }

    /// A hero orb sized for portrait buries the composer in landscape.
    private var heroOrbSize: CGFloat {
        verticalSizeClass == .compact ? 72 : 128
    }

    /// The transcript is the only content worth the taller detent.
    private var isShowingTranscript: Bool {
        vm.showsTranscript && (!vm.messages.isEmpty || vm.endedConversation != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            if let banner = vm.banner {
                ChatBannerView(
                    banner: banner,
                    strings: strings,
                    theme: vm.widgetConfig.theme,
                    onOpenSettings: vm.openSettings,
                    onDismiss: vm.dismissBanner
                )
            }
            header
            Divider()
            content
            ChatInputBar(vm: vm, isInputFocused: $isInputFocused)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            Text(strings.mainLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.banner)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cornerRadius,
                topTrailingRadius: Self.cornerRadius,
                style: .continuous
            )
            .fill(Color(.systemBackground))
            .ignoresSafeArea(edges: .bottom)
            .shadow(color: .black.opacity(0.18), radius: 24, y: -4)
        }
        .offset(y: dragOffset)
        .contentShape(Rectangle())
        .onTapGesture { isInputFocused = false }
        .onChange(of: isShowingTranscript) { _ in syncDetentToTranscript() }
        .onAppear(perform: syncDetentToTranscript)
        .task {
            // Text-only opens straight into typing; wait out the drawer animation
            // so the keyboard reliably comes up.
            guard !vm.supportsVoice, vm.canShowTextInput else { return }
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !vm.supportsVoice, vm.canShowTextInput else { return }
            isInputFocused = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isShowingTranscript {
            Spacer(minLength: 0)
            orb(size: heroOrbSize)
            Spacer(minLength: 0)
        } else {
            // A voice-only drawer has no composer to anchor it, so the orb stays
            // visible above the transcript.
            if !vm.canShowTextInput {
                orb(size: heroOrbSize * 0.75).padding(.vertical, 12)
            }
            ChatTranscriptView(vm: vm)
        }
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
        .padding(.bottom, 12)
    }

    // MARK: - Drag

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 48, height: 5)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture(perform: toggleDetent)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(detent == .compact ? strings.expandChatLabel : strings.collapseChatLabel)
    }

    /// Measured globally: the gesture sits inside a view this same drag offsets, so
    /// a local space would feed the offset back into the translation and jitter.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let translation = value.translation.height
                // Down follows the finger; up has no taller detent to reveal, so it
                // only tugs.
                dragOffset = translation >= 0 ? translation : rubberBand(translation)
            }
            .onEnded { value in
                endDrag(predicted: value.predictedEndTranslation.height)
            }
    }

    private func endDrag(predicted: CGFloat) {
        // Keep the offset when closing so the exit continues from the finger
        // rather than snapping back first.
        switch (detent, predicted) {
        case (.expanded, 220...): onClose()
        case (.expanded, 100...): setDetent(.compact)
        case (.compact, 100...): onClose()
        case (.compact, ...(-60)): setDetent(.expanded)
        default: withAnimation(Self.detentSpring) { dragOffset = 0 }
        }
    }

    private func toggleDetent() {
        setDetent(detent == .compact ? .expanded : .compact)
    }

    private func setDetent(_ target: ChatDrawerDetent) {
        withAnimation(Self.detentSpring) {
            detent = target
            dragOffset = 0
        }
    }

    /// Voice drawers open as a peek and grow once there is a transcript to read.
    private func syncDetentToTranscript() {
        guard vm.supportsVoice else { return }
        setDetent(isShowingTranscript ? .expanded : .compact)
    }

    /// Diminishing travel for a drag with no detent behind it.
    private func rubberBand(_ translation: CGFloat) -> CGFloat {
        let limit: CGFloat = 56
        return -limit * (1 - 1 / (abs(translation) / limit + 1))
    }
}
#endif
