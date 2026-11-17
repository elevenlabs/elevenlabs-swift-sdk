#if os(iOS)
import SwiftUI

/// Voice-only controls around the orb: a call button on it while idle, mute and end beside it during a call.
@available(iOS 16, macCatalyst 16, *)
struct ChatVoiceControls: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let orbSize: CGFloat

    private static let callDiameter: CGFloat = 56
    /// Separates the call button from the orb it overlaps.
    private static let callRingWidth: CGFloat = 4
    private static let sideDiameter: CGFloat = 48

    private var strings: ChatWidgetStrings {
        vm.widgetConfig.strings
    }

    private var theme: ChatWidgetTheme {
        vm.widgetConfig.theme
    }

    var body: some View {
        if vm.canEndConversation {
            HStack {
                // Holds the mic's place while connecting, so the orb doesn't shift when it appears.
                if vm.canToggleMicMute {
                    ChatMicButton(vm: vm, levels: vm.audioLevels, diameter: Self.sideDiameter, theme: theme)
                } else {
                    Color.clear.frame(width: Self.sideDiameter, height: Self.sideDiameter)
                }
                Spacer(minLength: 0)
                orb
                Spacer(minLength: 0)
                endButton
            }
            .padding(.horizontal, 24)
        } else {
            orb
                .overlay(alignment: .bottom) {
                    startButton.alignmentGuide(.bottom) { $0[VerticalAlignment.center] }
                }
                .padding(.bottom, Self.callDiameter / 2 + Self.callRingWidth)
        }
    }

    private var orb: some View {
        ChatOrbView(levels: vm.audioLevels, state: vm.orbState, size: orbSize, theme: theme)
    }

    private var startButton: some View {
        Button(action: vm.startConversation) {
            Image(systemName: "phone.fill")
                .font(.system(size: Self.callDiameter * 0.36, weight: .semibold))
                .foregroundColor(Color(.systemBackground))
                .frame(width: Self.callDiameter, height: Self.callDiameter)
                .background(Circle().fill(Color.primary))
                .padding(Self.callRingWidth)
                .background(Circle().fill(Color(.systemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.startConversationLabel)
    }

    private var endButton: some View {
        Button(action: vm.endConversation) {
            Image(systemName: "stop.fill")
                .font(.system(size: Self.sideDiameter * 0.34, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: Self.sideDiameter, height: Self.sideDiameter)
                .background(Circle().fill(theme.destructive))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.endConversationLabel)
    }
}
#endif
