#if canImport(UIKit)
import SwiftUI

/// Scrollable message transcript with smart bottom-pinning. Owns all of its
/// scroll-tracking state; the host passes the view model, widget config, and a
/// binding to the composer's focus state (used to re-pin when the keyboard
/// toggles). Extracted from `ChatPopupView`.
@available(iOS 16, macCatalyst 16, *)
struct ChatTranscriptView: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let widgetConfig: ChatWidgetConfig
    var isInputFocused: FocusState<Bool>.Binding

    @State private var scrollTask: Task<Void, Never>?
    @State private var transcriptScrolledFromTop: Bool = false
    @State private var transcriptShouldStayPinnedToBottom: Bool = true
    // Underlying geometry that drives the two flags above. Tracked via two
    // GeometryReader backgrounds (one inside the LazyVStack, one on the
    // ScrollView) because iOS 16 doesn't have `onScrollGeometryChange`.
    @State private var transcriptVisibleHeight: CGFloat = 0
    @State private var transcriptOffsetY: CGFloat = 0
    @State private var transcriptContentHeight: CGFloat = 0

    private let endedCardId = "ended-feedback-card"
    private let bottomAnchorId = "chat-bottom-anchor"

    /// Height of the fade-out gradient at the bottom edge of the transcript.
    private static let transcriptBottomFade: CGFloat = 32
    /// Empty space appended after the last message so a fully scrolled-down
    /// transcript clears the fade / overlapping view. Combined with the list
    /// spacing + bottom padding this clears the fade, keeping the last message
    /// crisp while resting close to the input bar.
    private static let transcriptBottomInset: CGFloat = 16

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(
                            message: msg,
                            showsFeedbackControls: shouldShowInConversationFeedback(for: msg),
                            theme: widgetConfig.theme,
                            strings: widgetConfig.strings
                        ) { score in
                            vm.sendInConversationFeedback(for: msg, score: score)
                        } onMCPApproval: { approved in
                            vm.respondToMCPApproval(for: msg, approved: approved)
                        }
                        // Ghost styling for the in-progress user caption, matching
                        // the live transcript while it is still tentative.
                        .opacity(msg.isPartial && msg.role == .user ? 0.55 : 1)
                        .id(msg.id)
                    }
                    if let ended = vm.endedConversation {
                        endedView(id: ended.id, endedByUser: ended.endedByUser)
                            .padding(.top, 12)
                            .id(endedCardId)
                    }
                    Color.clear
                        .frame(height: Self.transcriptBottomInset)
                        .id(bottomAnchorId)
                }
                .padding(12)
                // Tracks the scroll content's frame in the transcript coordinate
                // space → `offsetY` (positive = scrolled down) + `contentHeight`.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TranscriptOffsetKey.self,
                            value: TranscriptOffsetMeasurement(
                                offsetY: -geo.frame(in: .named(transcriptCoordinateSpace)).minY,
                                contentHeight: geo.size.height
                            )
                        )
                    }
                )
            }
            .coordinateSpace(name: transcriptCoordinateSpace)
            .scrollDismissesKeyboard(.interactively)
            // Fade the bottom edge so content dissolves as it slides behind the
            // overlapping input bar / orb.
            .mask(alignment: .top) { transcriptFadeMask }
            // Tracks the ScrollView's frame → `visibleHeight`. Background, not
            // overlay, so a Color.clear never intercepts hit-testing.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TranscriptVisibleHeightKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onPreferenceChange(TranscriptOffsetKey.self) { measurement in
                transcriptOffsetY = measurement.offsetY
                transcriptContentHeight = measurement.contentHeight
                transcriptScrolledFromTop = measurement.offsetY > 0.5
                // Only update the "should-stay-pinned" flag based on actual user
                // scrolling, not layout-driven offset shifts. We rely on the
                // visible-height handler to handle layout-change pinning.
                if transcriptVisibleHeight > 0 {
                    let distanceToBottom = measurement.contentHeight - (measurement.offsetY + transcriptVisibleHeight)
                    transcriptShouldStayPinnedToBottom = distanceToBottom <= 80
                }
            }
            .onPreferenceChange(TranscriptVisibleHeightKey.self) { newHeight in
                let oldHeight = transcriptVisibleHeight
                let didResize = abs(oldHeight - newHeight) > 0.5
                transcriptVisibleHeight = newHeight
                guard didResize else { return }
                // Treat "near the bottom" as pinned: the transcript carries a
                // bottom spacer, a fade mask and an overlapping footer, so an
                // exact match never happens and a tight threshold would read as
                // "not at bottom". Compute against the OLD visible height so we
                // judge intent before the layout shift took effect.
                let oldDistanceToBottom = transcriptContentHeight - (transcriptOffsetY + oldHeight)
                let wasPinned = oldDistanceToBottom <= 80
                if wasPinned {
                    transcriptShouldStayPinnedToBottom = true
                }
                if transcriptShouldStayPinnedToBottom {
                    scheduleScrollToBottomDuringLayoutChange(proxy: proxy)
                }
            }
            .onChange(of: isInputFocused.wrappedValue) { _ in
                guard transcriptShouldStayPinnedToBottom else { return }
                scheduleScrollToBottomDuringLayoutChange(proxy: proxy)
            }
            .overlay(alignment: .top) {
                // Hairline appears only when content has scrolled above the top
                // edge, signaling there's more transcript above the fold.
                Rectangle()
                    .fill(widgetConfig.theme.border)
                    .frame(height: 1)
                    .opacity(transcriptScrolledFromTop ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: transcriptScrolledFromTop)
            }
            .onChange(of: vm.messages.count) { _ in
                scheduleScrollToBottom(proxy: proxy)
            }
            .onChange(of: vm.scrollVersion) { _ in
                scheduleScrollToBottom(proxy: proxy)
            }
            .onChange(of: vm.endedConversation) { _ in
                guard vm.endedConversation != nil else { return }
                scheduleScrollToBottom(proxy: proxy, delayNanoseconds: 220_000_000, force: true)
            }
            .onChange(of: vm.draftAttachment) { _ in
                scheduleScrollToBottom(proxy: proxy)
            }
            .onChange(of: vm.isUploadingAttachment) { _ in
                scheduleScrollToBottom(proxy: proxy)
            }
            .onAppear {
                guard shouldAutoScrollContent else { return }
                scheduleScrollToBottom(proxy: proxy)
            }
        }
    }

    /// Opaque for the bulk of the transcript, fading to clear over the bottom
    /// `transcriptBottomFade` points so content dissolves behind the overlapping
    /// view instead of being hard-clipped.
    private var transcriptFadeMask: some View {
        GeometryReader { geo in
            let height = max(geo.size.height, 1)
            let fadeStart = max(0, (height - Self.transcriptBottomFade) / height)
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: fadeStart),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var shouldAutoScrollContent: Bool {
        !vm.messages.isEmpty || vm.endedConversation != nil || vm.draftAttachment != nil || vm.isUploadingAttachment
    }

    private func scheduleScrollToBottom(
        proxy: ScrollViewProxy,
        delayNanoseconds: UInt64 = 70_000_000,
        force: Bool = false
    ) {
        if force {
            scrollTask?.cancel()
        } else {
            guard scrollTask == nil else { return }
        }

        scrollTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            scrollToBottom(proxy: proxy)
            scrollTask = nil
        }
    }

    private func scheduleScrollToBottomDuringLayoutChange(proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            await Task.yield()

            // Keyboard presentation/dismissal animates the scroll view through a
            // few intermediate heights. Re-apply bottom anchoring through that
            // animation so the final resting geometry is also pinned.
            let checkpoints: [UInt64] = [
                0,
                80_000_000,
                180_000_000,
                320_000_000,
                500_000_000
            ]
            var previous: UInt64 = 0
            for checkpoint in checkpoints {
                let delay = checkpoint - previous
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy: proxy)
                previous = checkpoint
            }

            scrollTask = nil
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchorId, anchor: .bottom)
    }

    private func endedView(id: String?, endedByUser: Bool) -> some View {
        VStack(spacing: 2) {
            Text(endedByUser ? widgetConfig.strings.userEndedConversation : widgetConfig.strings.agentEndedConversation)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let id {
                Text(String(format: widgetConfig.strings.conversationIdFormat, id))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 17)
    }

    private func shouldShowInConversationFeedback(for message: ChatMessage) -> Bool {
        guard widgetConfig.enableInConversationFeedback,
              message.role == .agent,
              message.kind != .error,
              message.eventId != nil
        else {
            return false
        }

        if message.feedbackScore != nil {
            return true
        }
        return vm.conversationState == .connected
    }
}

// MARK: - Transcript scroll tracking (iOS 16 equivalent of `onScrollGeometryChange`)
//
// `ChatTranscriptView` needs three pieces of geometry to drive its smart-scroll
// behavior:
//   1. Scroll offset (Y) — how far the user has scrolled down
//   2. Content height — total transcript height
//   3. Visible height — the ScrollView's visible area
//
// iOS 18's `onScrollGeometryChange` exposes all three in one shot.
// iOS 16-17 doesn't, so we reconstruct them with two `GeometryReader`
// backgrounds + two `PreferenceKey`s.

private let transcriptCoordinateSpace = "ChatPopupTranscript"

private struct TranscriptOffsetMeasurement: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
}

private struct TranscriptOffsetKey: PreferenceKey {
    static var defaultValue: TranscriptOffsetMeasurement = .init(offsetY: 0, contentHeight: 0)
    static func reduce(value: inout TranscriptOffsetMeasurement, nextValue: () -> TranscriptOffsetMeasurement) {
        value = nextValue()
    }
}

private struct TranscriptVisibleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#endif
