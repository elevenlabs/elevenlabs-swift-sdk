struct ChatHistoryReconciler {
    private(set) var items: [any ChatHistoryItem] = []

    mutating func appendUserMessage(_ content: String) {
        items.append(Message(
            role: .user,
            content: content,
            isFinal: true
        ))
    }

    mutating func receive(_ event: TentativeUserTranscriptEvent) {
        removeTentativeUserMessages()
        items.append(Message(
            role: .user,
            content: event.transcript,
            isFinal: false,
            eventId: event.eventId
        ))
    }

    mutating func receive(_ event: UserTranscriptEvent) {
        if let index = items.firstIndex(where: {
            $0.message?.role == .user
                && $0.message?.eventId == event.eventId
        }) {
            updateMessage(at: index) {
                $0.content = event.transcript
                $0.isFinal = true
            }
            return
        }

        removeTentativeUserMessages()
        items.append(Message(
            role: .user,
            content: event.transcript,
            isFinal: true,
            eventId: event.eventId
        ))
    }

    mutating func receive(_ event: AgentChatResponsePartEvent) {
        if let index = items.firstIndex(where: { $0.id == event.responseId }) {
            updateMessage(at: index) {
                guard !$0.isFinal else { return }
                $0.content += event.text
            }
            return
        }

        items.append(Message(
            role: .agent,
            content: event.text,
            isFinal: false,
            eventId: event.eventId,
            responseId: event.responseId
        ))
    }

    mutating func receive(_ event: AgentResponseEvent) {
        upsertAgentMessage(
            responseId: event.responseId,
            eventId: event.eventId,
            content: event.response
        )
    }

    mutating func receive(_ event: AgentResponseCorrectionEvent) {
        upsertAgentMessage(
            responseId: event.responseId,
            eventId: event.eventId,
            content: event.correctedAgentResponse
        )
    }

    mutating func receive(_ event: AgentToolResponseEvent) {
        guard !items.contains(where: {
            $0.toolCall?.toolCallId == event.toolCallId
        }) else { return }
        items.append(ConversationToolCall(
            toolCallId: event.toolCallId,
            toolName: event.toolName
        ))
    }

    private mutating func upsertAgentMessage(responseId: String, eventId: Int, content: String) {
        if let index = items.firstIndex(where: { $0.id == responseId }) {
            updateMessage(at: index) {
                $0.content = content
                $0.isFinal = true
                $0.eventId = eventId
            }
        } else {
            items.append(Message(
                role: .agent,
                content: content,
                isFinal: true,
                eventId: eventId,
                responseId: responseId
            ))
        }
    }

    private mutating func updateMessage(at index: Int, update: (inout Message) -> Void) {
        guard var message = items[index] as? Message else { return }
        update(&message)
        items[index] = message
    }

    private mutating func removeTentativeUserMessages() {
        items.removeAll {
            guard let message = $0.message else { return false }
            return message.role == .user
                && !message.isFinal
        }
    }

}
