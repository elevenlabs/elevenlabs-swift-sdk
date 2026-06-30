import SwiftUI
import ElevenLabs
import ElevenLabsWidget

struct ContentView: View {
    let authProvider: () async throws -> ConversationAuth = {
        return ConversationAuth.publicAgent(id: "agent_7901knp31fjmfn8sh4jm50k011mj")
    }
    let launcher: () -> AnyView = { AnyView(Text("Chat")) }
    @State private var conversationMode: WidgetConversationMode = .voiceAndTextWithTextOnly
    @State private var collectFeedbackAfterCall = false
    @State private var enableTermsAndConditions = false

    var body: some View {
        ZStack() {
            VStack(spacing: 24) {
                Text("ElevenLabs Demo App")
                    .font(.title)

                Picker("Conversation Mode", selection: $conversationMode) {
                    ForEach(WidgetConversationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Post-conversation feedback", isOn: $collectFeedbackAfterCall)
                Toggle("Terms & conditions sheet", isOn: $enableTermsAndConditions)
            }
            .padding()
            ChatWidget(
                authProvider: authProvider,
                widgetConfig: ChatWidgetConfig(
                    conversationMode: conversationMode,
                    collectFeedbackAfterCall: collectFeedbackAfterCall,
                    enableTermsAndConditions: enableTermsAndConditions,
                    enableFileUpload: true
                ),
                conversationConfig: ConversationConfig(
                    audioConfiguration: .default,
                    relayOnly: false,
                    logLevel: .debug
                ),
                //            launcher: launcher
            )
            .id("\(conversationMode.rawValue)-\(collectFeedbackAfterCall)-\(enableTermsAndConditions)")
        }
    }
}
