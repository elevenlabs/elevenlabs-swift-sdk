#if canImport(UIKit)
import SwiftUI
import ElevenLabs
import UIKit

enum ChatDrawerDetent {
    case compact
    case expanded
}

@available(iOS 16, macCatalyst 16, *)
public struct ChatWidget: View {
    @StateObject private var vm: ChatWidgetViewModel
    private let widgetConfig: ChatWidgetConfig
    private let launcher: (() -> AnyView)?
    @State private var detent: ChatDrawerDetent = .expanded
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @MainActor public init(
        authProvider: @escaping () async throws -> ConversationAuth,
        widgetConfig: ChatWidgetConfig? = nil,
        conversationConfig: ConversationConfig? = nil,
        controller: ChatWidgetController? = nil,
        launcher: (() -> AnyView)? = nil,
        onClientToolCall: (@MainActor (ClientToolCallEvent) async -> ClientToolResultEvent)? = nil,
        onConversationStarted: (@MainActor () -> Void)? = nil
    ) {
        self.widgetConfig = widgetConfig ?? .default
        self.launcher = launcher
        let resolvedConfig = conversationConfig ?? ConversationConfig()
        let vm = ChatWidgetViewModel(
            authProvider: authProvider,
            widgetConfig: self.widgetConfig,
            client: ConversationClient(),
            conversationConfig: resolvedConfig,
            onClientToolCall: onClientToolCall,
            onConversationStarted: onConversationStarted
        )
        if let controller {
            vm.attach(to: controller)
        }
        // `@StateObject` must be assigned through its backing wrapper exactly
        // once; the VM is constructed above so the optional controller can be
        // attached before SwiftUI takes ownership of it.
        _vm = StateObject(wrappedValue: vm)
    }
    
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.allowsHitTesting(false)
            
            if widgetConfig.showBackdrop {
                // Kept always-mounted (rather than inserted/removed) so hit-testing
                // can switch off the instant we close. A removal transition would
                // keep the full-screen backdrop intercepting taps on the host UI
                // for the duration of its fade-out.
                Color.black
                    .opacity(vm.isOpen ? 0.2 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(vm.isOpen)
                    .onTapGesture { animateClose() }
            }
            
            if vm.isOpen {
                ChatPopupView(
                    vm: vm,
                    widgetConfig: widgetConfig,
                    detent: $detent,
                    onClose: animateClose
                )
                .frame(maxWidth: .infinity)
                .frame(maxHeight: detent == .compact ? compactDrawerHeight : .infinity)
                .padding(.top, detent == .expanded ? 64 : 0)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if let launcher {
                    Button(action: animateToggle) {
                        launcher()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(widgetConfig.strings.openChatLabel)
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    FloatingChatButton(
                        onTap: animateToggle,
                        orbState: vm.orbState,
                        agentLevels: vm.outputLevels,
                        userLevels: vm.inputLevels,
                        theme: widgetConfig.theme,
                        accessibilityLabel: widgetConfig.strings.openChatLabel
                    )
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
    
    private var compactDrawerHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        // In landscape (compact height class) a half sheet is uselessly short –
        // it can't fit the header, orb and input bar, so the orb ends up
        // overlapping them. Make the compact detent nearly full height there.
        if verticalSizeClass == .compact {
            return screenHeight * 0.92
        }
        // Voice-only modes have no input bar, so the compact sheet can be
        // shorter – otherwise there's excess empty space above the orb.
        let fraction: CGFloat = widgetConfig.conversationMode.supportsTextInput ? 0.5 : 0.4
        return screenHeight * fraction
    }
    
    private func animateToggle() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            vm.toggleOpen()
        }
    }
    
    /// Idempotent dismissal. Used by the backdrop and the drawer's close action so
    /// a second tap landing during the close transition can't toggle it back open.
    private func animateClose() {
        guard vm.isOpen else { return }
        // Resign the keyboard up front so it retracts together with the sheet.
        // Otherwise the focused text field keeps first-responder status until the
        // collapse transition finishes tearing the view down, leaving the
        // keyboard hanging on screen for the duration of the animation.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            vm.close()
        }
    }
}

#endif
