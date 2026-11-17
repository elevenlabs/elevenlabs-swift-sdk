#if os(iOS)
import SwiftUI

@available(iOS 16, macCatalyst 16, *)
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            bubbleText
                .foregroundColor(message.role == .user ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(message.role == .user ? Color.black : Color(.secondarySystemBackground))
                )
            if message.role == .agent { Spacer(minLength: 40) }
        }
    }

    private var bubbleText: Text {
        let content = Text(message.content).font(.body)
        guard !message.isFinal else { return content }
        return content + Text("\u{2588}").font(.body.monospaced()).baselineOffset(2)
    }
}
#endif
