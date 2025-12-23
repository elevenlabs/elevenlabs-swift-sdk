import Foundation

// swiftlint:disable cyclomatic_complexity function_body_length

@MainActor
extension Conversation {
    // MARK: - Event Handling

    func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case let .userTranscript(e):
            appendUserTranscript(e.transcript)
            options.onUserTranscript?(e.transcript, e.eventId)

        case .tentativeAgentResponse:
            // Don't change agent state - let voice activity detection handle it
            break

        case let .agentResponse(e):
            appendAgentMessage(e.response)
            lastAgentEventId = e.eventId
            options.onAgentResponse?(e.response, e.eventId)
            if lastFeedbackSubmittedEventId.map({ e.eventId > $0 }) ?? true {
                options.onCanSendFeedbackChange?(true)
            }

        case let .agentResponseCorrection(correction):
            // Handle agent response corrections
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
            handleAgentChatResponsePart(e)

        case let .audio(audioEvent):
            latestAudioEvent = audioEvent
            latestAudioAlignment = audioEvent.alignment
            if let alignment = audioEvent.alignment {
                options.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            // Only interruption should force listening state - immediately, no timeout
            speakingTimer?.cancel()
            agentState = .listening
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
            // VAD scores are available in the event stream
            options.onVadScore?(vad.vadScore)

        case let .agentToolResponse(toolResponse):
            // Agent tool response is available in the event stream
            agentState = .listening

            if toolResponse.toolName == "end_call" {
                await endConversation()
            }
            options.onAgentToolResponse?(toolResponse)

        case let .agentToolRequest(toolRequest):
            // Forward agent tool request to consumer
            // Switch to thinking while the agent performs the tool call
            agentState = .thinking
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

        case .error:
            logger.error("Received error event from server")
            // Error events are available in the event stream
        }
    }

    func handleAgentChatResponsePart(_ event: AgentChatResponsePartEvent) {
        switch event.type {
        case .start:
            let newMessage = Message(
                id: UUID().uuidString,
                role: .agent,
                content: event.text,
                timestamp: Date()
            )
            currentStreamingMessage = newMessage
            messages.append(newMessage)

        case .delta:
            guard let streamingMessage = currentStreamingMessage else {
                handleAgentChatResponsePart(
                    AgentChatResponsePartEvent(text: event.text, type: .start)
                )
                return
            }

            messages.removeAll { $0.id == streamingMessage.id }
            let updatedContent = streamingMessage.content + event.text
            let updatedMessage = Message(
                id: streamingMessage.id,
                role: .agent,
                content: updatedContent,
                timestamp: streamingMessage.timestamp
            )
            currentStreamingMessage = updatedMessage
            messages.append(updatedMessage)

        case .stop:
            if let streamingMessage = currentStreamingMessage {
                if !event.text.isEmpty {
                    messages.removeAll { $0.id == streamingMessage.id }
                    let finalContent = streamingMessage.content + event.text
                    let finalMessage = Message(
                        id: streamingMessage.id,
                        role: .agent,
                        content: finalContent,
                        timestamp: streamingMessage.timestamp
                    )
                    messages.append(finalMessage)
                }
            }
            currentStreamingMessage = nil
        }
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length
