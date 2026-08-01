#if os(iOS)
import SwiftUI

/// Default launcher: a mini orb in the corner of the host UI.
@available(iOS 16, macCatalyst 16, *)
struct FloatingChatButton: View {
    let orbState: ChatOrbState
    let theme: ChatWidgetTheme
    let accessibilityLabel: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ChatOrbView(state: orbState, size: 58, theme: theme)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
#endif
