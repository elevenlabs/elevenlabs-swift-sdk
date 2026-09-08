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
            options.onUserTranscript?(e.transcript, e.eventId)

        case .tentativeAgentResponse:
            agentStateManager?.processSignal(.agentResponse)

        case let .agentResponse(e):
            upsertAgentMessage(content: e.response, eventId: e.eventId, responseId: e.responseId)
            lastAgentEventId = e.eventId
            agentStateManager?.processSignal(.agentResponse)
            options.onAgentResponse?(e.response, e.eventId)
            if lastFeedbackSubmittedEventId.map({ e.eventId > $0 }) ?? true {
                options.onCanSendFeedbackChange?(true)
            }

        case let .agentResponseCorrection(correction):
            upsertAgentMessage(
                content: correction.correctedAgentResponse,
                eventId: correction.eventId,
                responseId: correction.responseId
            )
            options.onAgentResponseCorrection?(
                correction.originalAgentResponse,
                correction.correctedAgentResponse,
                correction.eventId
            )

        case let .agentResponseMetadata(metadata):
            options.onAgentResponseMetadata?(
                metadata.metadataData,
                metadata.eventId
            )

        case let .agentChatResponsePart(e):
            appendAgentResponsePart(e)

        case let .audio(audioEvent):
            latestAudioEvent = audioEvent
            latestAudioAlignment = audioEvent.alignment
            if let alignment = audioEvent.alignment {
                options.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            speakingTimer?.cancel()
            applyStateSignal(.interruption, fallback: .listening)
            options.onInterruption?(interruptionEvent.eventId)
            options.onCanSendFeedbackChange?(false)

        case let .conversationMetadata(metadata):
            // Store the conversation metadata for public access
            conversationMetadata = metadata
            options.onConversationMetadata?(metadata)

        case let .ping(p):
            // Respond to ping with pong
            let pong = OutgoingEvent.pong(PongEvent(eventId: p.eventId))
            try? await publish(pong)

        case let .clientToolCall(toolCall):
            // Add to pending tool calls for the app to handle
            options.onUnhandledClientToolCall?(toolCall)
            pendingToolCalls.append(toolCall)

        case let .vadScore(vad):
            agentStateManager?.processSignal(.vadScore(vad.vadScore))
            options.onVadScore?(vad.vadScore)

        case let .agentToolResponse(toolResponse):
            applyStateSignal(.agentToolResponse, fallback: .listening)

            if toolResponse.toolName == "end_call" {
                await endConversation()
            }
            options.onAgentToolResponse?(toolResponse)

        case let .agentToolRequest(toolRequest):
            applyStateSignal(.agentToolRequest, fallback: .thinking)
            options.onAgentToolRequest?(toolRequest)

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

        case .asrInitiationMetadata:
            // ASR initiation metadata is available in the event stream
            break

        case let .error(errorEvent):
            logger.error("Received error event from server: code=\(errorEvent.code), message=\(errorEvent.message ?? "none")")
            options.onError?(.serverError(errorEvent))
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
            eventId: eventId,
            responseId: nil,
            isFinal: true
        )
        if let agentIdx = messages.firstIndex(where: { $0.role == .agent && $0.eventId == eventId }) {
            messages.insert(message, at: agentIdx)
        } else {
            messages.append(message)
        }
    }

    private func upsertAgentMessage(content: String, eventId: Int, responseId: String) {
        guard let idx = messages.lastIndex(where: { $0.responseId == responseId }) else {
            appendMessage(role: .agent, content: content, eventId: eventId, responseId: responseId)
            return
        }
        messages[idx] = messages[idx].updating(content: content, isFinal: true)
    }

    private func appendAgentResponsePart(_ event: AgentChatResponsePartEvent) {
        let isFinal = event.type == .stop
        guard let idx = messages.lastIndex(where: { $0.responseId == event.responseId }) else {
            appendMessage(
                role: .agent,
                content: event.text,
                eventId: event.eventId,
                responseId: event.responseId,
                isFinal: isFinal
            )
            return
        }
        // A part arriving after `agent_response` delivered the final text is stale.
        let existing = messages[idx]
        guard !existing.isFinal else { return }
        messages[idx] = existing.updating(content: existing.content + event.text, isFinal: isFinal)
    }
}
