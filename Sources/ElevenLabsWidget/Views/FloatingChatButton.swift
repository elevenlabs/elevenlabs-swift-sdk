#if canImport(UIKit)
import ElevenLabs
import SwiftUI

struct FloatingChatButton: View {
    let onTap: () -> Void
    var orbState: ChatOrbState = .disconnected
    let agentLevels: AudioLevelMonitor
    let userLevels: AudioLevelMonitor
    var theme: ChatWidgetTheme = .default
    var accessibilityLabel: String = ChatWidgetStrings.default.openChatLabel

    var body: some View {
        Button(action: onTap) {
            ChatOrbView(state: orbState, agentLevels: agentLevels, userLevels: userLevels, size: 58, theme: theme)
                .padding(3)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

#endif
