import ElevenLabs
import ElevenLabsWidget
import SwiftUI

/// Minimal host for `ChatWidget`. Paste a public agent ID below to try it.
struct ContentView: View {
    /// Paste a public agent ID here, then rebuild.
    private static let agentId = ""

    @StateObject private var chat = ChatWidgetController()

    private var hasAgentId: Bool {
        !Self.agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("ElevenLabs Agents")
                    .font(.title)

                Text(
                    """
                    This is a demo app for ElevenLabs Agents. You can either \
                    import the widget into your app, or import the core SDK \
                    and implement your own UI.
                    """
                )
                .foregroundStyle(.secondary)

                if hasAgentId {
                    Text("Agent ID is set — open the chat button to start.")
                        .foregroundStyle(.secondary)
                    hostControls
                } else {
                    Text(
                        """
                        Set `ContentView.agentId` to a public agent ID, then \
                        rebuild to try the widget.
                        """
                    )
                    .foregroundStyle(.orange)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if hasAgentId {
                ChatWidget(
                    authProvider: { .publicAgent(id: Self.agentId) },
                    controller: chat
                )
            }
        }
    }

    private var hostControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stateDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Open chat") { chat.open() }
                Button("Close chat") { chat.close() }
                Button("End call") {
                    Task { await chat.endConversation() }
                }
                .disabled(!chat.state.isConnected)
            }
            .buttonStyle(.bordered)
        }
    }

    private var stateDescription: String {
        switch chat.state {
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .ended: "Ended"
        case .error: "Error"
        }
    }
}
