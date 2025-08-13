import Foundation
import LiveKit
import os.log

/// Receives and processes ElevenLabs messages from the data channel
/// Provides AsyncStreams for different event types, following modern Swift concurrency patterns
@available(macOS 11.0, iOS 14.0, *)
actor DataChannelReceiver: MessageReceiver {
    private let room: Room
    private let logger = Logger(subsystem: "VoiceAgent", category: "DataChannelReceiver")

    // Stream continuations for different event types
    private var messageContinuation: AsyncStream<ReceivedMessage>.Continuation?
    private var eventContinuation: AsyncStream<IncomingEvent>.Continuation?

    init(room: Room) {
        self.room = room
        room.add(delegate: self)
    }

    deinit {
        room.remove(delegate: self)
    }

    // MARK: - Public API

    /// Stream of chat messages (agent responses and user transcripts)
    func messages() async throws -> AsyncStream<ReceivedMessage> {
        let (stream, continuation) = AsyncStream<ReceivedMessage>.makeStream()
        messageContinuation = continuation

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.cleanup()
            }
        }

        return stream
    }

    /// Stream of all ElevenLabs events for advanced use cases
    func events() async -> AsyncStream<IncomingEvent> {
        let (stream, continuation) = AsyncStream<IncomingEvent>.makeStream()
        eventContinuation = continuation
        return stream
    }

    // MARK: - Private Methods

    private func cleanup() {
        messageContinuation = nil
        eventContinuation = nil
    }

    private func yield(message: ReceivedMessage) {
        messageContinuation?.yield(message)
    }

    private func yield(event: IncomingEvent) {
        eventContinuation?.yield(event)
    }
}

// MARK: - RoomDelegate

@available(macOS 11.0, iOS 14.0, *)
extension DataChannelReceiver: RoomDelegate {
    nonisolated func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        // Only process messages from the agent
        guard let participant else {
            print("[DataChannelReceiver] Received data but no participant, ignoring")
            return
        }
        Task {
            await handleDataMessage(data)
        }
    }

    private func handleDataMessage(_ data: Data) async {
        do {
            guard let event = try EventParser.parseIncomingEvent(from: data) else {
                return
            }
            yield(event: event)

            switch event {
            case let .agentResponse(responseEvent):
                handleAgentResponse(responseEvent)

            case let .agentResponseCorrection(correctionEvent):
                handleAgentResponseCorrection(correctionEvent)

            case let .userTranscript(transcriptEvent):
                handleUserTranscript(transcriptEvent)

            case let .interruption(interruptionEvent):
                handleInterruption(interruptionEvent)

            case let .vadScore(vadScoreEvent):
                handleVadScore(vadScoreEvent)

            case let .tentativeAgentResponse(tentativeEvent):
                handleTentativeAgentResponse(tentativeEvent)

            case let .audio(audioEvent):
                // Audio is handled separately via WebRTC audio tracks
                logger.debug("Received audio event with ID: \(audioEvent.eventId)")

            case let .conversationMetadata(metadataEvent):
                handleConversationMetadata(metadataEvent)

            case let .ping(pingEvent):
                await handlePing(pingEvent)

            case let .clientToolCall(toolCallEvent):
                handleClientToolCall(toolCallEvent)

            case let .agentToolResponse(toolResponseEvent):
                handleAgentToolResponse(toolResponseEvent)
            }
        } catch {
            logger.error("Failed to parse incoming event: \(error)")
        }
    }

    private func handleAgentResponse(_ event: AgentResponseEvent) {
        let message = ReceivedMessage(
            id: UUID().uuidString,
            timestamp: Date(),
            content: .agentTranscript(event.response),
        )
        yield(message: message)
        logger.debug("Agent response: \(event.response)")
    }

    private func handleAgentResponseCorrection(_ event: AgentResponseCorrectionEvent) {
        // For corrections, we yield a new message with the corrected content
        // In a more sophisticated implementation, you might update the original message
        let message = ReceivedMessage(
            id: UUID().uuidString,
            timestamp: Date(),
            content: .agentTranscript(event.correctedAgentResponse),
        )
        yield(message: message)
        logger.debug("Agent correction: \(event.originalAgentResponse) -> \(event.correctedAgentResponse)")
    }

    private func handleUserTranscript(_ event: UserTranscriptEvent) {
        let message = ReceivedMessage(
            id: UUID().uuidString,
            timestamp: Date(),
            content: .userTranscript(event.transcript),
        )
        yield(message: message)
        logger.debug("User transcript: \(event.transcript)")
    }

    private func handleInterruption(_ event: InterruptionEvent) {
        logger.info("User interrupted the agent (event ID: \(event.eventId))")
        // Interruptions don't generate messages, but are available in the event stream
    }

    private func handleVadScore(_ event: VadScoreEvent) {
        logger.info("VAD score: \(event.vadScore)")
        // VAD scores are available in the event stream
    }

    private func handleTentativeAgentResponse(_ event: TentativeAgentResponseEvent) {
        logger.debug("Tentative response: \(event.tentativeResponse)")
        // Tentative responses are available in the event stream but don't generate messages
        // You could extend ReceivedMessage to include tentative responses if needed
    }

    private func handleConversationMetadata(_ event: ConversationMetadataEvent) {
        logger.info("Conversation initialized with ID: \(event.conversationId)")
        if let userFormat = event.userInputAudioFormat {
            logger.debug("User audio format: \(userFormat)")
        }
    }

    private func handlePing(_ event: PingEvent) async {
        // Automatically respond with pong
        let pongEvent = PongEvent(eventId: event.eventId)
        let outgoingEvent = OutgoingEvent.pong(pongEvent)

        do {
            let data = try EventSerializer.serializeOutgoingEvent(outgoingEvent)
            try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: true))
        } catch {
            logger.error("Failed to send pong response: \(error)")
        }
    }

    private func handleClientToolCall(_ event: ClientToolCallEvent) {
        logger.info("Received client tool call: \(event.toolName) (ID: \(event.toolCallId))")
        // Tool calls are available in the event stream
    }

    private func handleAgentToolResponse(_ event: AgentToolResponseEvent) {
        logger.info("Received agent tool response: \(event.toolName) (ID: \(event.toolCallId), Type: \(event.toolType), Error: \(event.isError))")
        // Agent tool responses are available in the event stream
    }
}
