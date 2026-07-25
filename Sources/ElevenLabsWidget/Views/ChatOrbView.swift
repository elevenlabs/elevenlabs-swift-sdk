#if canImport(UIKit)
import SwiftUI

enum ChatOrbState {
    case connecting
    case listening
    case speaking
    case disconnected
}

/// Placeholder orb: a themed gradient sphere that breathes while the agent is
/// speaking. Replaced by the Metal visualizer without changing its call sites.
@available(iOS 16, macCatalyst 16, *)
struct ChatOrbView: View {
    let state: ChatOrbState
    let size: CGFloat
    var theme: ChatWidgetTheme = .default

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [theme.orbSecondary, theme.orbPrimary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(state == .disconnected ? 0.55 : 1)
            .scaleEffect(isPulsing ? 1 : 0.92)
            .frame(width: size, height: size)
            // Only the breathing itself repeats; settling back is a one-shot.
            .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.25), value: isPulsing)
            .onAppear { isPulsing = state == .speaking || state == .connecting }
            .onChange(of: state) { isPulsing = $0 == .speaking || $0 == .connecting }
    }
}
#endif
