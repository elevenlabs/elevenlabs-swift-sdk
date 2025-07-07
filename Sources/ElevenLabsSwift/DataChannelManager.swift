import Foundation
import LiveKit
import os.log

@available(macOS 11.0, iOS 14.0, *)
public class DataChannelManager: @unchecked Sendable {
    private let room: Room
    private let callbacks: ElevenLabsSDK.Callbacks
    private let clientTools: ElevenLabsSDK.ClientTools?

    private let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "DataChannelManager")

    init(room: Room, callbacks: ElevenLabsSDK.Callbacks, clientTools: ElevenLabsSDK.ClientTools?) {
        self.room = room
        self.callbacks = callbacks
        self.clientTools = clientTools
        setupDataChannelHandling()
    }

    private func setupDataChannelHandling() {
        room.add(delegate: self)
    }

    func sendConversationInitiation(_ config: ElevenLabsSDK.SessionConfig) async throws {
        var initMessage: [String: Any] = ["type": "conversation_initiation_client_data"]

        if let overrides = config.overrides {
            initMessage["conversation_config_override"] = overrides.dictionary
        }

        if let customBody = config.customLlmExtraBody {
            initMessage["custom_llm_extra_body"] = customBody.mapValues { $0.jsonValue }
        }

        if let dynamicVars = config.dynamicVariables {
            initMessage["dynamic_variables"] = dynamicVars.mapValues { $0.jsonValue }
        }

        // Send immediately and wait for completion to ensure it's sent before proceeding
        try await sendMessageImmediate(initMessage)
        logger.info("Conversation initiation sent")
    }

    // Immediate synchronous send for critical messages like conversation initiation
    func sendMessageImmediate(_ message: [String: Any]) async throws {
        let messageType = message["type"] as? String ?? "unknown"
        
        // Wait for local participant to be ready
        var retries = 0
        while room.connectionState != .connected || room.localParticipant.sid?.stringValue.isEmpty ?? true {
            if retries > 10 {
                throw ElevenLabsSDK.ElevenLabsError.connectionFailed("Local participant not ready after retries")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            retries += 1
        }

        let messageData = try JSONSerialization.data(withJSONObject: message)
        try await room.localParticipant.publish(data: messageData)
        logger.debug("Data message sent immediately: \(messageType)")
    }

    func sendMessage(_ message: [String: Any]) {
        // Create a local copy of the message data before the Task
        let messageData: Data
        let messageType = message["type"] as? String ?? "unknown"

        do {
            messageData = try JSONSerialization.data(withJSONObject: message)
        } catch {
            logger.error("Failed to serialize message: \(error.localizedDescription)")
            callbacks.onError("Failed to serialize message", error)
            return
        }

        Task { @Sendable in
            do {
                try await room.localParticipant.publish(data: messageData)
                logger.debug("Data message sent: \(messageType)")
            } catch {
                logger.error("Failed to send data message: \(error.localizedDescription)")
                await MainActor.run {
                    callbacks.onError("Failed to send message", error)
                }
            }
        }
    }

    private func handleIncomingMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            logger.error("Failed to parse incoming message")
            callbacks.onError("Failed to parse incoming message", nil)
            return
        }

        // Filter out audio messages for WebRTC - they're handled via audio tracks
        if type == "audio" {
            return
        }

        logger.debug("Received message type: \(type)")

        switch type {
        case "conversation_initiation_metadata":
            handleConversationInitiation(json)
        case "agent_response":
            handleAgentResponse(json)
        case "user_transcript":
            handleUserTranscript(json)
        case "agent_response_correction":
            handleAgentResponseCorrection(json)
        case "client_tool_call":
            handleClientToolCall(json)
        case "interruption":
            handleInterruption(json)
        case "ping":
            handlePing(json)
        default:
            logger.debug("Unknown message type: \(type)")
        }
    }

    private func handleConversationInitiation(_ json: [String: Any]) {
        guard let event = json["conversation_initiation_metadata_event"] as? [String: Any],
              let conversationId = event["conversation_id"] as? String
        else {
            logger.error("Invalid conversation initiation metadata")
            return
        }

        callbacks.onConnect(conversationId)
        logger.info("Conversation initiated with ID: \(conversationId)")
    }

    private func handleAgentResponse(_ json: [String: Any]) {
        guard let event = json["agent_response_event"] as? [String: Any],
              let response = event["agent_response"] as? String
        else {
            logger.error("Invalid agent response format")
            return
        }

        callbacks.onMessage(response, .ai)
    }

    private func handleUserTranscript(_ json: [String: Any]) {
        guard let event = json["user_transcription_event"] as? [String: Any],
              let transcript = event["user_transcript"] as? String
        else {
            logger.error("Invalid user transcript format")
            return
        }

        callbacks.onMessage(transcript, .user)
    }

    private func handleAgentResponseCorrection(_ json: [String: Any]) {
        guard let event = json["agent_response_correction_event"] as? [String: Any],
              let originalResponse = event["original_agent_response"] as? String,
              let correctedResponse = event["corrected_agent_response"] as? String
        else {
            logger.error("Invalid agent response correction format")
            return
        }

        callbacks.onMessageCorrection(originalResponse, correctedResponse, .ai)
    }

    private func handleClientToolCall(_ json: [String: Any]) {
        guard let toolCall = json["client_tool_call"] as? [String: Any],
              let toolName = toolCall["tool_name"] as? String,
              let toolCallId = toolCall["tool_call_id"] as? String,
              let parameters = toolCall["parameters"] as? [String: Any]
        else {
            logger.error("Invalid client tool call format")
            callbacks.onError("Invalid client tool call format", json)
            return
        }

        // Capture the values we need as Sendable types
        let capturedToolName = toolName
        let capturedToolCallId = toolCallId

        // Serialize parameters to Data (which is Sendable)
        let parametersData: Data
        do {
            parametersData = try JSONSerialization.data(withJSONObject: parameters)
        } catch {
            logger.error("Failed to serialize parameters: \(error.localizedDescription)")
            callbacks.onError("Failed to serialize parameters", error)
            return
        }

        Task { @Sendable in
            do {
                // Deserialize parameters back to [String: Any]
                let deserializedParameters = try JSONSerialization.jsonObject(with: parametersData) as? [String: Any] ?? [:]

                let result = try await clientTools?.handle(capturedToolName, parameters: deserializedParameters)

                let response: [String: Any] = [
                    "type": "client_tool_result",
                    "tool_call_id": capturedToolCallId,
                    "result": result ?? "",
                    "is_error": false,
                ]
                sendMessage(response)

            } catch {
                logger.error("Client tool execution failed: \(error.localizedDescription)")

                let response: [String: Any] = [
                    "type": "client_tool_result",
                    "tool_call_id": capturedToolCallId,
                    "result": error.localizedDescription,
                    "is_error": true,
                ]
                sendMessage(response)
            }
        }
    }

    private func handleInterruption(_: [String: Any]) {
        callbacks.onModeChange(.listening)
        logger.debug("Interruption received")
    }

    private func handlePing(_ json: [String: Any]) {
        guard let event = json["ping_event"] as? [String: Any],
              let eventId = event["event_id"] as? Int
        else {
            logger.error("Invalid ping event format")
            return
        }

        let response: [String: Any] = [
            "type": "pong",
            "event_id": eventId,
        ]
        sendMessage(response)
        logger.debug("Pong sent for event ID: \(eventId)")
    }
}

// MARK: - Room Delegate

@available(macOS 11.0, iOS 14.0, *)
extension DataChannelManager: RoomDelegate {
    public func room(_: Room, didReceive data: Data, from _: RemoteParticipant?) {
        handleIncomingMessage(data)
    }
}
