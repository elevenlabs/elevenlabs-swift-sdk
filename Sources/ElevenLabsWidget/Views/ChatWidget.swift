#if os(iOS)
import ElevenLabs
import SwiftUI
import UIKit

/// A drop-in chat widget: a launcher in the corner of your UI that opens a
/// drawer with the agent conversation.
///
/// Overlay it on your own content, typically in a `ZStack`:
///
/// ```swift
/// ChatWidget(mode: .voiceAndText(.publicAgent(id: "agent_id")))
/// ```
@available(iOS 16, macCatalyst 16, *)
public struct ChatWidget: View {
    @StateObject private var vm: ChatWidgetViewModel
    private let mode: WidgetConversationMode
    private let widgetConfig: ChatWidgetConfig
    private let conversationConfig: ConversationConfig
    private let controller: ChatWidgetController?
    private let launcher: (() -> AnyView)?
    private let onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)?

    @State private var detent: ChatDrawerDetent = .expanded
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// - Parameters:
    ///   - mode: How the user can talk to the agent, and the credentials each
    ///     kind of session needs. Credentials are minted per session.
    ///   - controller: Optional handle for driving the widget from the host.
    ///   - launcher: Replaces the default orb launcher.
    ///   - onClientToolCall: Handles client tool calls from the agent.
    @MainActor public init(
        mode: WidgetConversationMode,
        widgetConfig: ChatWidgetConfig = .default,
        conversationConfig: ConversationConfig = .init(),
        controller: ChatWidgetController? = nil,
        launcher: (() -> AnyView)? = nil,
        onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)? = nil
    ) {
        self.mode = mode
        self.widgetConfig = widgetConfig
        self.conversationConfig = conversationConfig
        self.controller = controller
        self.launcher = launcher
        self.onClientToolCall = onClientToolCall
        // Built inside the autoclosure so SwiftUI only creates it once, rather
        // than on every re-init of this view.
        _vm = StateObject(wrappedValue: ChatWidgetViewModel(
            mode: mode,
            widgetConfig: widgetConfig,
            client: ConversationClient(),
            conversationConfig: conversationConfig,
            onClientToolCall: onClientToolCall
        ))
    }

    public var body: some View {
        // This view is rebuilt on every host update while the view model
        // survives, so session configuration and host closures are handed over
        // fresh here rather than left at whatever the first mount captured.
        // None are published, so these assignments invalidate nothing.
        vm.mode = mode
        vm.conversationConfig = conversationConfig
        vm.onClientToolCall = onClientToolCall
        return ZStack(alignment: .bottomTrailing) {
            if vm.widgetConfig.showBackdrop {
                // Always mounted so hit-testing switches off the instant we close;
                // a removal transition would keep swallowing taps while fading out.
                Color.black
                    .opacity(vm.isOpen ? 0.2 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(vm.isOpen)
                    .onTapGesture(perform: vm.close)
            }

            if vm.isOpen {
                ChatPopupView(vm: vm, detent: $detent, onClose: vm.close)
                    .frame(maxHeight: detent == .compact ? compactDrawerHeight : .infinity)
                    .padding(.top, detent == .expanded ? 64 : 0)
                    .transition(.move(edge: .bottom))
            } else {
                launcherView
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Attaching seeds the controller's mirrors, so it has to happen outside a
        // view update — otherwise the host's controller invalidates the view that
        // is still being built.
        .task { if let controller { vm.attach(to: controller) } }
        // The private client belongs to this visible widget. Once the host
        // removes it, no UI remains to represent a live microphone or session.
        .onDisappear(perform: vm.endConversation)
        // Published, so it can't be assigned mid-update like the mode above.
        .onChange(of: widgetConfig) { vm.widgetConfig = $0 }
    }

    /// Half height reads as a peek in portrait, but in landscape it leaves the
    /// composer fighting the keyboard, so the compact detent is nearly full there.
    private var compactDrawerHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        guard verticalSizeClass != .compact else { return screenHeight * 0.92 }
        return screenHeight * (vm.canShowTextInput ? 0.5 : 0.4)
    }

    @ViewBuilder
    private var launcherView: some View {
        if let launcher {
            Button(action: vm.toggleOpen) { launcher() }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.widgetConfig.strings.openChatLabel)
        } else {
            FloatingChatButton(vm: vm, onTap: vm.toggleOpen)
        }
    }
}
#endif
