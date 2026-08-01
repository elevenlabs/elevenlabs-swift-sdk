#if os(iOS)
import SwiftUI

@available(iOS 16, macCatalyst 16, *)
struct ChatTranscriptView: View {
    @ObservedObject var vm: ChatWidgetViewModel

    private static let endedFooterId = "transcript.ended"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let ended = vm.endedConversation {
                        endedFooter(ended).id(Self.endedFooterId)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Keyed on every message, so an insert or an edit above the last
            // bubble scrolls too, not just a change to the newest text.
            .onChange(of: vm.messages.map(\.content)) { _ in scrollToBottom(proxy) }
            .onChange(of: vm.endedConversation) { _ in scrollToBottom(proxy) }
        }
    }

    private func endedFooter(_ ended: ChatWidgetViewModel.EndedConversation) -> some View {
        let strings = vm.widgetConfig.strings
        return VStack(spacing: 2) {
            Text(ended.endedByUser ? strings.userEndedConversation : strings.agentEndedConversation)
                .font(.subheadline)
            if let id = ended.id {
                Text(String(format: strings.conversationIdFormat, id))
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let last: AnyHashable? = vm.endedConversation == nil ? vm.messages.last?.id : Self.endedFooterId
        guard let last else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
    }
}
#endif
