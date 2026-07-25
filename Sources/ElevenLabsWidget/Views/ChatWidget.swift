#if canImport(UIKit)
import ElevenLabs
import SwiftUI

/// A drop-in chat widget: a launcher in the corner of your UI that opens a
/// drawer with the agent conversation.
///
/// Overlay it on your own content, typically in a `ZStack`:
///
/// ```swift
/// ChatWidget(authProvider: { .publicAgent(id: "agent_id") })
/// ```
@available(iOS 16, macCatalyst 16, *)
public struct ChatWidget: View {
    @StateObject private var vm: ChatWidgetViewModel
    private let controller: ChatWidgetController?
    private let launcher: (() -> AnyView)?

    /// - Parameters:
    ///   - authProvider: Called before each conversation starts, so short-lived
    ///     tokens can be minted on demand.
    ///   - controller: Optional handle for driving the widget from the host.
    ///   - launcher: Replaces the default orb launcher.
    ///   - onClientToolCall: Handles client tool calls from the agent.
    @MainActor public init(
        authProvider: @escaping () async throws -> ConversationCredentials,
        widgetConfig: ChatWidgetConfig = .default,
        conversationConfig: ConversationConfig = .init(),
        controller: ChatWidgetController? = nil,
        launcher: (() -> AnyView)? = nil,
        onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)? = nil
    ) {
        self.controller = controller
        self.launcher = launcher
        // Built inside the autoclosure so SwiftUI only creates it once, rather
        // than on every re-init of this view.
        _vm = StateObject(wrappedValue: ChatWidgetViewModel(
            authProvider: authProvider,
            widgetConfig: widgetConfig,
            client: ConversationClient(),
            conversationConfig: conversationConfig,
            onClientToolCall: onClientToolCall
        ))
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
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
                ChatPopupView(vm: vm, onClose: vm.close)
                    .padding(.top, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                launcherView
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // Attaching seeds the controller's mirrors, so it has to happen outside a
        // view update — otherwise the host's controller invalidates the view that
        // is still being built.
        .task { if let controller { vm.attach(to: controller) } }
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
