import Foundation

@MainActor
extension Conversation {
    // MARK: - Event Handling

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case let .userTranscript(e):
            insertUserTranscript(content: e.transcript, eventId: e.eventId)
            agentStateManager?.processSignal(.userTranscript)
            callbacks.onUserTranscript?(e.transcript, e.eventId)

        case let .agentResponse(e):
            upsertAgentMessage(content: e.response, eventId: e.eventId)
            lastAgentEventId = e.eventId
            agentStateManager?.processSignal(.agentResponse)
            callbacks.onAgentResponse?(e.response, e.eventId)
            if lastFeedbackSubmittedEventId.map({ e.eventId > $0 }) ?? true {
                callbacks.onCanSendFeedbackChange?(true)
            }

        case let .agentResponseCorrection(correction):
            upsertAgentMessage(content: correction.correctedAgentResponse, eventId: correction.eventId)
            callbacks.onAgentResponseCorrection?(
                correction.originalAgentResponse,
                correction.correctedAgentResponse,
                correction.eventId
            )

        case let .agentResponseMetadata(metadata):
            callbacks.onAgentResponseMetadata?(
                metadata.metadataData,
                metadata.eventId
            )

        case let .agentChatResponsePart(e):
            let existing = messages.last(where: { $0.role == .agent && $0.eventId == e.eventId })?.content ?? ""
            upsertAgentMessage(content: existing + e.text, eventId: e.eventId)

        case let .audio(audioEvent):
            if let alignment = audioEvent.alignment {
                callbacks.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            speakingTimer?.cancel()
            applyStateSignal(.interruption, fallback: .listening)
            callbacks.onInterruption?(interruptionEvent.eventId)
            callbacks.onCanSendFeedbackChange?(false)

        case let .conversationMetadata(metadata):
            // Store the conversation metadata for public access
            conversationMetadata = metadata
            callbacks.onConversationMetadata?(metadata)

        case let .ping(p):
            // Respond to ping with pong
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case let .clientToolCall(toolCall):
            // Add to pending tool calls for the app to handle
            callbacks.onUnhandledClientToolCall?(toolCall)
            pendingToolCalls.append(toolCall)

        case let .vadScore(vad):
            agentStateManager?.processSignal(.vadScore(vad.vadScore))
            callbacks.onVadScore?(vad.vadScore)

        case let .agentToolResponse(toolResponse):
            applyStateSignal(.agentToolResponse, fallback: .listening)

            if toolResponse.toolName == "end_call" {
                await endConversation()
            }
            callbacks.onAgentToolResponse?(toolResponse)

        case let .agentToolRequest(toolRequest):
            applyStateSignal(.agentToolRequest, fallback: .thinking)
            callbacks.onAgentToolRequest?(toolRequest)

        case .tentativeUserTranscript:
            // Tentative user transcript (in-progress transcription)
            break

        case let .mcpToolCall(toolCall):
            // Update or append MCP tool call based on toolCallId
            if let index = mcpToolCalls.firstIndex(where: { $0.toolCallId == toolCall.toolCallId }) {
                mcpToolCalls[index] = toolCall
            } else {
                mcpToolCalls.append(toolCall)
            }

        case let .mcpConnectionStatus(status):
            // Update MCP connection status
            mcpConnectionStatus = status

        case let .error(errorEvent):
            logger.error("Received error event from server: code=\(errorEvent.code), message=\(errorEvent.message ?? "none")")
            callbacks.onError?(.serverError(errorEvent))
        }
    }

    /// Inserts the user transcript before the agent message with the same `eventId`
    /// if one exists, since the agent's response may be received before the transcript.
    private func insertUserTranscript(content: String, eventId: Int) {
        let message = Message(
            id: UUID().uuidString,
            role: .user,
            content: content,
            timestamp: Date(),
            eventId: eventId
        )
        if let agentIdx = messages.firstIndex(where: { $0.role == .agent && $0.eventId == eventId }) {
            messages.insert(message, at: agentIdx)
        } else {
            messages.append(message)
        }
    }

    private func upsertAgentMessage(content: String, eventId: Int) {
        if let idx = messages.lastIndex(where: { $0.role == .agent && $0.eventId == eventId }) {
            let existing = messages[idx]
            messages[idx] = Message(
                id: existing.id,
                role: .agent,
                content: content,
                timestamp: existing.timestamp,
                eventId: eventId
            )
        } else {
            appendMessage(role: .agent, content: content, eventId: eventId)
        }
    }
}
