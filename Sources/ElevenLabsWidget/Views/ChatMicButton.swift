#if canImport(UIKit)
import SwiftUI

/// Circular microphone toggle with a live input-level fill and a muted slash.
@available(iOS 16, macCatalyst 16, *)
struct ChatMicButton: View {
    @ObservedObject var vm: ChatWidgetViewModel
    /// Observed directly so the fill tracks the mic while redrawing only this button.
    @ObservedObject var levels: OrbAudioLevels
    let diameter: CGFloat
    var theme: ChatWidgetTheme = .default

    private var micLevel: CGFloat {
        vm.isMicMuted ? 0 : CGFloat(levels.input)
    }

    var body: some View {
        Button(action: vm.toggleMicMute) {
            ZStack {
                Circle().fill(Color(.systemBackground))

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Color.accentColor
                            .opacity(0.18 + micLevel * 0.25)
                            .frame(height: geometry.size.height * micLevel)
                    }
                }
                .clipShape(Circle())

                Circle().strokeBorder(theme.border, lineWidth: 1)

                Image(systemName: vm.isMicMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: diameter * 0.42))
                    .foregroundColor(.black)
            }
            .frame(width: diameter, height: diameter)
            .animation(.linear(duration: 0.06), value: micLevel)
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
