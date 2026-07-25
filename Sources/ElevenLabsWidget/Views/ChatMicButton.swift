#if canImport(UIKit)
import SwiftUI

/// Circular microphone toggle with a muted slash.
@available(iOS 16, macCatalyst 16, *)
struct ChatMicButton: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let diameter: CGFloat
    var theme: ChatWidgetTheme = .default

    var body: some View {
        Button(action: vm.toggleMicMute) {
            Image(systemName: vm.isMicMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: diameter * 0.42))
                .foregroundColor(.black)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color(.systemBackground)))
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            vm.isMicMuted
                ? vm.widgetConfig.strings.unmuteMicrophoneLabel
                : vm.widgetConfig.strings.muteMicrophoneLabel
        )
    }
}
#endif
