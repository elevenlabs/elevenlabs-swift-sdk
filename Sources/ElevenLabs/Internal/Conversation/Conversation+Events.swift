import Foundation

@MainActor
extension Conversation {
    // MARK: - Event Handling

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handleIncomingEvent(_ event: IncomingEvent) async {
        switch event {
        case let .userTranscript(e):
            applyUserTranscript(content: e.transcript, eventId: e.eventId)
            callbacks.onUserTranscript?(e.transcript, e.eventId)
            agentStateManager?.processSignal(.userTranscript)

        case let .tentativeUserTranscript(e):
            applyTentativeUserTranscript(content: e.transcript, eventId: e.eventId)
            callbacks.onTentativeUserTranscript?(e.transcript, e.eventId)

        case let .agentResponse(e):
            applyAgentResponse(content: e.response, eventId: e.eventId)
            callbacks.onAgentResponse?(e.response, e.eventId)
            agentStateManager?.processSignal(.agentResponse)

        case let .agentResponseCorrection(correction):
            applyAgentResponse(
                content: correction.correctedAgentResponse,
                eventId: correction.eventId
            )
            callbacks.onAgentResponseCorrection?(
                correction.originalAgentResponse,
                correction.correctedAgentResponse,
                correction.eventId
            )

        case let .agentChatResponsePart(e):
            applyAgentResponsePart(text: e.text, type: e.type, eventId: e.eventId)
            callbacks.onAgentResponsePart?(e.text, e.type, e.eventId)

        case let .agentResponseMetadata(metadata):
            callbacks.onAgentResponseMetadata?(
                metadata.metadataData,
                metadata.eventId
            )

        case let .audio(audioEvent):
            if let alignment = audioEvent.alignment {
                callbacks.onAudioAlignment?(alignment)
            }

        case let .interruption(interruptionEvent):
            speakingTimer?.cancel()
            isAgentSpeaking = false
            feedAgentState(.interruption, fallback: .listening)
            callbacks.onInterruption?(interruptionEvent.eventId)

        case let .conversationMetadata(metadata):
            conversationMetadata = metadata
            // This event completes the startup handshake: release any waiter
            // blocking `connect()` on metadata receipt.
            resumeConversationMetadataWaiter()

        case let .ping(p):
            if let pingMs = p.pingMs {
                callbacks.onPing?(pingMs)
            }
            // Send pong off the serialized handler loop: awaiting the publish
            // here would let a slow transport stall delivery of every queued
            // event behind this heartbeat. Pong is keyed by `eventId`, so
            // out-of-order delivery is fine.
            let eventId = p.eventId
            Task { @MainActor [weak self] in
                try? await self?.publish(.pong(PongEvent(eventId: eventId)))
            }

        case let .vadScore(vad):
            callbacks.onVadScore?(vad.vadScore)
            agentStateManager?.processSignal(.vadScore(vad.vadScore))

        case let .clientToolCall(toolCall):
            // Append before invoking the callback so a handler that inspects
            // `pendingToolCalls` (directly or via the mirrored client property)
            // already sees the new call.
            pendingToolCalls.append(toolCall)
            callbacks.onClientToolCall?(toolCall)

        case let .agentToolRequest(toolRequest):
            feedAgentState(.agentToolRequest, fallback: .thinking)
            callbacks.onAgentToolRequest?(toolRequest)

        case let .agentToolResponse(toolResponse):
            feedAgentState(.agentToolResponse, fallback: .listening)
            callbacks.onAgentToolResponse?(toolResponse)

        case let .mcpToolCall(toolCall):
            if let index = mcpToolCalls.firstIndex(where: { $0.toolCallId == toolCall.toolCallId }) {
                mcpToolCalls[index] = toolCall
            } else {
                mcpToolCalls.append(toolCall)
            }

        case let .mcpConnectionStatus(status):
            mcpConnectionStatus = status

        case let .error(errorEvent):
            logger.error("Received error event from server: code=\(errorEvent.code), name=\(errorEvent.errorName ?? "none"), message=\(errorEvent.message ?? "none")")
            callbacks.onError?(.serverError(errorEvent))
        }
    }

    // MARK: - Transcript / response reconciliation
    //
    // `messages` is keyed by role + event id and only ever appended, never
    // reordered, so order follows the arrival of finalized text:
    //   * Finalized text (`agent_response`, `agent_response_correction`,
    //     `user_transcript`) is always recorded — a matching event id updates in
    //     place, otherwise it's appended (even out of order).
    //   * Streaming parts (`agent_chat_response_part`, `tentative_user_transcript`)
    //     only open a new partial when their event id is newer than the role's
    //     highest; otherwise they're stale and ignored.
    // Event ids stay unique per role; partial user transcripts are cleared on
    // every tentative/final user transcript.

    /// `agent_chat_response_part`: accumulates streamed text. A finalized message
    /// (`.stop` already seen) is never reopened, and a stale part (older than the
    /// agent's highest event id) never opens a new bubble.
    private func applyAgentResponsePart(text: String, type: AgentChatResponsePartType, eventId: Int) {
        let isPartial = type != .stop
        guard let idx = messageIndex(role: .agent, eventId: eventId) else {
            if isNewerThanHighestEventId(role: .agent, eventId: eventId) {
                appendMessage(role: .agent, content: text, eventId: eventId, isPartial: isPartial)
            }
            return
        }
        guard messages[idx].isPartial else { return }
        messages[idx] = messages[idx].updating(content: messages[idx].content + text, eventId: eventId, isPartial: isPartial)
    }

    /// `agent_response` | `agent_response_correction`: the finalized response for a
    /// turn. Replaces the matching message in place, or records it (appending,
    /// even out of order) when no slot exists yet.
    private func applyAgentResponse(content: String, eventId: Int) {
        if let idx = messageIndex(role: .agent, eventId: eventId) {
            messages[idx] = messages[idx].updating(content: content, eventId: eventId, isPartial: false)
        } else {
            appendMessage(role: .agent, content: content, eventId: eventId, isPartial: false)
        }
    }

    /// `user_transcript`: the finalized user transcript. Finalizes the matching
    /// in-progress partial, or records it (appending, even out of order) when no
    /// slot exists; then drops any leftover partial (a tentative that never
    /// produced its own final).
    private func applyUserTranscript(content: String, eventId: Int) {
        if let idx = messageIndex(role: .user, eventId: eventId) {
            messages[idx] = messages[idx].updating(content: content, eventId: eventId, isPartial: false)
        } else {
            appendMessage(role: .user, content: content, eventId: eventId, isPartial: false)
        }
        // A finalized transcript ends the turn, so any leftover in-progress
        // partial is stale and removed.
        messages.removeAll { $0.role == .user && $0.isPartial }
    }

    /// `tentative_user_transcript`: the in-progress user transcript. Supersedes any
    /// existing partial, then surfaces a fresh one if it belongs to a turn newer
    /// than the user's highest event id.
    private func applyTentativeUserTranscript(content: String, eventId: Int) {
        messages.removeAll { $0.role == .user && $0.isPartial }
        guard isNewerThanHighestEventId(role: .user, eventId: eventId) else { return }
        appendMessage(role: .user, content: content, eventId: eventId, isPartial: true)
    }

    /// Index of the `role` message with exactly `eventId`, scanning tail-first so
    /// the common "touch the latest message" case is cheap. Event ids are unique
    /// per role (matches update in place), so first/last match the same element.
    private func messageIndex(role: Message.Role, eventId: Int) -> Int? {
        messages.lastIndex { $0.role == role && $0.eventId == eventId }
    }

    /// Whether `eventId` is greater than the highest event id recorded for `role`.
    /// Uses the max rather than the last message, because finalized responses can
    /// append out of order and locally-sent messages carry no event id (skipped).
    private func isNewerThanHighestEventId(role: Message.Role, eventId: Int) -> Bool {
        guard let highest = messages.compactMap({ $0.role == role ? $0.eventId : nil }).max() else { return true }
        return eventId > highest
    }

    private func appendMessage(role: Message.Role, content: String, eventId: Int, isPartial: Bool) {
        messages.append(
            Message(
                id: UUID().uuidString,
                role: role,
                content: content,
                timestamp: Date(),
                eventId: eventId,
                isPartial: isPartial
            )
        )
    }
}

private extension Message {
    /// A copy with new `content`/`eventId`/`isPartial`, preserving the stable
    /// `id`, `role`, and `timestamp` so SwiftUI identity and ordering hold.
    func updating(content: String, eventId: Int?, isPartial: Bool) -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            eventId: eventId,
            isPartial: isPartial
        )
    }
}
