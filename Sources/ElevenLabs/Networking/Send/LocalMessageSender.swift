import Foundation
import LiveKit

/// An actor that sends local messages to the agent.
/// Currently, it only supports sending text messages.
///
/// It also serves as the loopback for the local messages,
/// so that they can be displayed in the message feed
/// without relying on the agent-side transcription.
actor LocalMessageSender: MessageSender, MessageReceiver {
    private let room: Room
    private let topic: String

    private var messageContinuation: AsyncStream<ReceivedMessage>.Continuation?

    init(room: Room, topic: String = "lk.chat") {
        self.room = room
        self.topic = topic
    }

    func send(_ message: SentMessage) async throws {
        guard case let .userText(text) = message.content else { return }

        // Always show in UI immediately
        let loopbackMessage = ReceivedMessage(
            id: message.id,
            timestamp: message.timestamp,
            content: .userTranscript(text)
        )
        messageContinuation?.yield(loopbackMessage)

        // Try to send to agent (don't throw if it fails)
        do {
            let userMessageEvent = UserMessageEvent(text: text)
            let outgoingEvent = OutgoingEvent.userMessage(userMessageEvent)
            let messageData = try EventSerializer.serializeOutgoingEvent(outgoingEvent)
            try await room.localParticipant.publish(data: messageData, options: DataPublishOptions(reliable: true))
        } catch {
            // Message is already shown in UI, just log the error
            print("Failed to send message to agent: \(error)")
        }
    }

    func messages() async throws -> AsyncStream<ReceivedMessage> {
        let (stream, continuation) = AsyncStream<ReceivedMessage>.makeStream()
        messageContinuation = continuation
        return stream
    }
}
