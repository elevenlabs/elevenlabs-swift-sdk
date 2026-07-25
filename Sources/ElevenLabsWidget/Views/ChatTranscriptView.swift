#if canImport(UIKit)
import SwiftUI

@available(iOS 16, macCatalyst 16, *)
struct ChatTranscriptView: View {
    @ObservedObject var vm: ChatWidgetViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: vm.messages.last?.content) { _ in
                guard let last = vm.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
#endif
