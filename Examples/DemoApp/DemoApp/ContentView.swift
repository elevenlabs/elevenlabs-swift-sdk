import ElevenLabs
import ElevenLabsWidget
import SwiftUI

/// Minimal host for `ChatWidget`.
struct ContentView: View {
    /// The shapes of `WidgetConversationMode` the demo can switch between.
    private enum Mode: String, CaseIterable, Identifiable {
        case voiceAndText = "Voice + text"
        case voiceOnly = "Voice only"
        case textOnly = "Text only"
        case either = "Either"

        var id: String {
            rawValue
        }

        var needsVoice: Bool {
            self != .textOnly
        }

        var needsTextOnly: Bool {
            self == .textOnly || self == .either
        }
    }

    private enum Auth: String, CaseIterable, Identifiable {
        case publicAgent = "Public agent"
        case backend = "From your backend"

        var id: String {
            rawValue
        }
    }

    @StateObject private var chat = ChatWidgetController()
    @State private var mode: Mode = .voiceAndText
    @State private var auth: Auth = .publicAgent

    @State private var agentId = ""
    @State private var conversationToken = ""
    @State private var signedWebSocketURL = ""

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

                credentialsForm

                if let missingCredentials {
                    Text(missingCredentials)
                        .foregroundStyle(.orange)
                } else {
                    Text("Credentials set — open the chat button to start.")
                        .foregroundStyle(.secondary)
                    hostControls
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if missingCredentials == nil {
                ChatWidget(mode: conversationMode, controller: chat)
            }
        }
    }

    // MARK: - Widget configuration

    private var conversationMode: WidgetConversationMode {
        switch mode {
        case .voiceAndText: .voiceAndText(voiceAuth)
        case .voiceOnly: .voiceOnly(voiceAuth)
        case .textOnly: .textOnly(textOnlyAuth)
        case .either: .voiceOrTextOnly(voice: voiceAuth, textOnly: textOnlyAuth)
        }
    }

    private var voiceAuth: WidgetConversationMode.VoiceAuth {
        switch auth {
        case .publicAgent: .publicAgent(id: agentId.trimmed)
        case .backend: .conversationToken { [token = conversationToken.trimmed] in token }
        }
    }

    private var textOnlyAuth: WidgetConversationMode.TextOnlyAuth {
        switch auth {
        case .publicAgent: .publicAgent(id: agentId.trimmed)
        case .backend: .signedWebSocketURL { [url = signedWebSocketURL.trimmed] in url }
        }
    }

    /// Why the demo can't start yet, or nil when it can.
    private var missingCredentials: String? {
        switch auth {
        case .publicAgent:
            agentId.trimmed.isEmpty ? "Enter a public agent ID to try the widget." : nil
        case .backend:
            if mode.needsVoice, conversationToken.trimmed.isEmpty {
                "Enter a conversation token from your backend for the voice call."
            } else if mode.needsTextOnly, signedWebSocketURL.trimmed.isEmpty {
                "Enter a signed WebSocket URL from your backend for text-only chat."
            } else {
                nil
            }
        }
    }

    // MARK: - Views

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Auth", selection: $auth) {
                ForEach(Auth.allCases) { auth in
                    Text(auth.rawValue).tag(auth)
                }
            }
            .pickerStyle(.segmented)

            switch auth {
            case .publicAgent:
                TextField("Public agent ID", text: $agentId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            case .backend:
                if mode.needsVoice {
                    SecureField("Conversation token (voice)", text: $conversationToken)
                        .textFieldStyle(.roundedBorder)
                }
                if mode.needsTextOnly {
                    TextField("Signed WebSocket URL (text-only)", text: $signedWebSocketURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
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
                // Enabled while connecting too: ending is what cancels a start.
                .disabled(!chat.state.isConnected && !chat.state.isConnecting)
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

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
