#if canImport(UIKit)
import ElevenLabs
import SwiftUI

/// Circular microphone button with live input-level fill and a muted slash.
/// `diameter` scales the glyph, border and slash proportionally (the design
/// uses 56pt in the voice-only controls and 38pt in the input bar). Shared by
/// both the voice-only controls and the input bar.
@available(iOS 16, macCatalyst 16, *)
struct ChatMicButton: View {
    @ObservedObject var vm: ChatWidgetViewModel
    /// Observed directly so the fill tracks the mic at audio rate while
    /// re-rendering only this button — never the rest of the widget.
    @ObservedObject var inputLevels: AudioLevelMonitor
    let diameter: CGFloat
    var theme: ChatWidgetTheme = .default

    private var micActivityLevel: CGFloat {
        guard !vm.isMicMuted else { return 0 }
        return CGFloat(inputLevels.level)
    }

    var body: some View {
        let slashScale = diameter / 56
        return Button(action: vm.toggleMicMute) {
            ZStack {
                Circle()
                    .fill(Color.white)

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Color.accentColor
                            .opacity(0.18 + micActivityLevel * 0.25)
                            .frame(height: geometry.size.height * micActivityLevel)
                    }
                }
                .clipShape(Circle())

                Circle()
                    .strokeBorder(theme.border, lineWidth: 1)

                MicShape()
                    .fill(Color.black, style: FillStyle(eoFill: true))
                if vm.isMicMuted {
                    ZStack {
                        Capsule().fill(Color.white).frame(width: 36 * slashScale, height: 6 * slashScale)
                        Capsule().fill(Color.black).frame(width: 32 * slashScale, height: 2.5 * slashScale)
                    }
                    .rotationEffect(.degrees(-45))
                }
            }
            .frame(width: diameter, height: diameter)
            .animation(.linear(duration: 0.06), value: micActivityLevel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.isMicMuted ? vm.widgetConfig.strings.unmuteMicrophoneLabel : vm.widgetConfig.strings.muteMicrophoneLabel)
    }
}

#endif
