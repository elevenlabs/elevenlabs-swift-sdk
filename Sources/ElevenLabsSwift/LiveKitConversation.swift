import AVFoundation
import Foundation
import LiveKit
import os.log

@available(macOS 11.0, iOS 14.0, *)
public class LiveKitConversation: @unchecked Sendable, LiveKitConversationProtocol {
    private let room: Room
    private let dataChannelManager: DataChannelManager
    private let audioManager: RTCLiveKitAudioManager
    private let callbacks: ElevenLabsSDK.Callbacks
    private let config: ElevenLabsSDK.SessionConfig
    private let clientTools: ElevenLabsSDK.ClientTools?
    private let token: String

    // State management
    private let statusLock = NSLock()
    private let modeLock = NSLock()
    private var _status: ElevenLabsSDK.Status = .connecting
    private var _mode: ElevenLabsSDK.Mode = .listening

    private let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "LiveKitConversation")

    private var status: ElevenLabsSDK.Status {
        get { statusLock.withLock { _status } }
        set { statusLock.withLock { _status = newValue } }
    }

    private var mode: ElevenLabsSDK.Mode {
        get { modeLock.withLock { _mode } }
        set { modeLock.withLock { _mode = newValue } }
    }

    init(token: String, config: ElevenLabsSDK.SessionConfig, callbacks: ElevenLabsSDK.Callbacks, clientTools: ElevenLabsSDK.ClientTools?) {
        self.token = token
        self.config = config
        self.callbacks = callbacks
        self.clientTools = clientTools

        logger.info("🎬 Initializing LiveKitConversation")
        logger.info("Token length: \(token.count)")
        logger.info("Config - AgentID: \(config.agentId ?? "nil"), Overrides: \(config.overrides != nil)")
        
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(),
            defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(),
            defaultAudioCaptureOptions: AudioCaptureOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                typingNoiseDetection: true
            )
        )

        room = Room(roomOptions: roomOptions)
        logger.info("🏠 Room created with audio options: echo=true, agc=true, noise=true")

        dataChannelManager = DataChannelManager(room: room, callbacks: callbacks, clientTools: clientTools)
        audioManager = RTCLiveKitAudioManager(room: room, callbacks: callbacks)

        setupEventHandlers()
    }

    private func setupEventHandlers() {
        room.add(delegate: self)
    }

    public func connect() async throws {
        updateStatus(.connecting)
        logger.info("🔌 Starting connection process")

        // Note: Audio session is configured in ElevenLabsSDK.startSession()
        // before this method is called, so we don't need to configure it again here

        do {
            // Connect without pre-connect audio first to ensure data channel is ready
            let connectOptions = ConnectOptions(
                autoSubscribe: true,
                enableMicrophone: true  // Enable microphone during connection
            )
            
            logger.info("📡 Connecting to LiveKit URL: \(ElevenLabsSDK.Constants.liveKitUrl)")
            logger.debug("Connect options: autoSubscribe=true, enableMicrophone=true")

            try await room.connect(url: ElevenLabsSDK.Constants.liveKitUrl, token: token, connectOptions: connectOptions)

            logger.info("✅ Room.connect completed, waiting for connection state")
            
            // Wait for room to be fully connected before proceeding
            try await waitForConnectionState(.connected)
            
            logger.info("✅ Room is connected, waiting for data channel")
            
            // Small delay to ensure data channel is ready
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            logger.info("📤 Sending conversation initiation")

            // Send conversation initiation after ensuring connection is stable
            try await dataChannelManager.sendConversationInitiation(config)
            
            logger.info("🎤 Initializing audio tracks")

            // Initialize audio tracks after data channel is ready
            try await audioManager.initialize()

            logger.info("✅ LiveKit conversation connected successfully")
            logger.info("Room SID: \(self.room.sid?.stringValue ?? "nil")")
            logger.info("Room Name: \(self.room.name ?? "nil")")
            logger.info("Local Participant: \(self.room.localParticipant.identity?.stringValue ?? "nil")")
        } catch {
            updateStatus(.disconnected)
            logger.error("❌ Failed to connect: \(error.localizedDescription)")
            logger.error("Error type: \(type(of: error))")
            throw error
        }
    }

    private func waitForConnectionState(_ targetState: ConnectionState) async throws {
        logger.info("⏳ Waiting for connection state: \(String(describing: targetState))")
        
        if room.connectionState == targetState {
            logger.info("✅ Already in target state")
            return
        }

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let timeout: TimeInterval = 30.0 // 30 seconds timeout
            var timeoutTask: Task<Void, Error>?

            logger.info("🔍 Setting up connection state observer")

            let observer = self.room.observe(\.connectionState) { [weak self] _, _ in
                guard let self = self, !hasResumed else { return }
                
                let currentState = self.room.connectionState
                self.logger.info("📊 Connection state changed to: \(String(describing: currentState))")

                switch currentState {
                case .connected where targetState == .connected:
                    hasResumed = true
                    timeoutTask?.cancel() // Cancel timeout on success
                    self.logger.info("✅ Reached connected state")
                    continuation.resume()
                case .disconnected:
                    hasResumed = true
                    timeoutTask?.cancel() // Cancel timeout on failure
                    self.logger.error("❌ Room disconnected while waiting")
                    let error = ElevenLabsSDK.ElevenLabsError.connectionFailed("Room disconnected unexpectedly")
                    continuation.resume(throwing: error)
                case .reconnecting:
                    // Continue waiting during reconnection
                    self.logger.warning("⚠️ Room is reconnecting...")
                    break
                case .connecting:
                    self.logger.info("🔄 Still connecting...")
                    break
                @unknown default:
                    self.logger.warning("⚠️ Unknown connection state")
                    break
                }
            }

            // Set up timeout with better error handling
            logger.info("⏱️ Setting up \(timeout) second timeout")
            timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) // Convert seconds to nanoseconds
                    if !hasResumed {
                        hasResumed = true
                        observer.invalidate()
                        self.logger.error("❌ Connection timed out after \(timeout) seconds")
                        let error = ElevenLabsSDK.ElevenLabsError.roomConnectionTimeout
                        continuation.resume(throwing: error)
                    }
                } catch {
                    // Task was cancelled, which is expected
                    self.logger.debug("Timeout task cancelled")
                }
            }
        }
    }

    // MARK: - Public API methods (matching current implementation)

    public func sendContextualUpdate(_ text: String) {
        let message: [String: Any] = [
            "type": "contextual_update",
            "text": text,
        ]
        dataChannelManager.sendMessage(message)
    }

    public func sendUserMessage(_ text: String? = nil) {
        var message: [String: Any] = ["type": "user_message"]
        if let text = text {
            message["text"] = text
        }
        dataChannelManager.sendMessage(message)
    }

    public func sendUserActivity() {
        let message: [String: Any] = ["type": "user_activity"]
        dataChannelManager.sendMessage(message)
    }

    public func endSession() {
        guard status == .connected else { return }

        updateStatus(.disconnecting)
        Task {
            await audioManager.close()
            await room.disconnect()
            updateStatus(.disconnected)
        }

        logger.info("LiveKit conversation ended")
    }

    // MARK: - Audio controls

    public var conversationVolume: Float {
        get { audioManager.volume }
        set { audioManager.setVolume(newValue) }
    }

    public func startRecording() {
        audioManager.setMicrophoneEnabled(true)
    }

    public func stopRecording() {
        audioManager.setMicrophoneEnabled(false)
    }

    // MARK: - Getters

    public func getId() -> String {
        return room.name ?? "unknown"
    }

    public func getInputVolume() -> Float {
        return 0 // Will be implemented with actual RTC stats
    }

    public func getOutputVolume() -> Float {
        return audioManager.volume
    }

    // MARK: - Real-time Audio Level Monitoring

    public func getCurrentInputLevel() -> Float {
        return audioManager.getCurrentInputLevel()
    }

    public func getCurrentOutputLevel() -> Float {
        return audioManager.getCurrentOutputLevel()
    }

    public func getInputLevelHistory() -> [Float] {
        return audioManager.getInputLevelHistory()
    }

    public func getOutputLevelHistory() -> [Float] {
        return audioManager.getOutputLevelHistory()
    }

    // MARK: - Internal state management

    func updateStatus(_ newStatus: ElevenLabsSDK.Status) {
        guard status != newStatus else { return }
        status = newStatus
        callbacks.onStatusChange(newStatus)
    }

    func updateMode(_ newMode: ElevenLabsSDK.Mode) {
        guard mode != newMode else { return }
        mode = newMode
        callbacks.onModeChange(newMode)
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        #if os(iOS) || os(tvOS)
            let audioSession = AVAudioSession.sharedInstance()

            do {
                try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                try audioSession.setPreferredIOBufferDuration(ElevenLabsSDK.Constants.ioBufferDuration)
                try audioSession.setPreferredSampleRate(ElevenLabsSDK.Constants.inputSampleRate)

                if audioSession.isInputGainSettable {
                    try audioSession.setInputGain(1.0)
                }

                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                logger.info("Audio session configured for WebRTC")

            } catch {
                logger.error("Failed to configure audio session: \(error.localizedDescription)")
                throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession(error.localizedDescription)
            }
        #else
            // macOS doesn't use AVAudioSession
            logger.info("Audio session configuration skipped on macOS")
        #endif
    }
}

// MARK: - Room Delegate

@available(macOS 11.0, iOS 14.0, *)
extension LiveKitConversation: RoomDelegate {
    public func roomDidConnect(_ room: Room) {
        updateStatus(.connected)
        if let conversationId = room.name {
            callbacks.onConnect(conversationId)
        }
    }

    public func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        updateStatus(.disconnected)
        callbacks.onDisconnect()
        if let error = error {
            logger.error("Room disconnected with error: \(error.localizedDescription)")
            logger.error("Error code: \(error.code), type: \(String(describing: error.type))")
        } else {
            logger.warning("Room disconnected without error - possible server-side rejection")
        }
    }

    public func room(_: Room, didFailToConnectWithError error: LiveKitError?) {
        updateStatus(.disconnected)
        callbacks.onError("Failed to connect to room", error)
        if let error = error {
            logger.error("Failed to connect to room: \(error.localizedDescription)")
            logger.error("Error code: \(error.code), type: \(String(describing: error.type))")
        
        }
    }

    public func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from oldState: ConnectionState) {
        // Handle connection state changes if needed
        let stateString = String(describing: connectionState)
        let oldStateString = String(describing: oldState)
        logger.debug("Connection state updated: \(oldStateString) -> \(stateString)")
        
        // Log additional details for debugging
        if connectionState == .disconnected {
            logger.warning("Disconnected - checking room details:")
            logger.warning("Room name: \(self.room.name ?? "nil")")
            logger.warning("Room sid: \(self.room.sid?.stringValue ?? "nil")")
            logger.warning("Local participant: \(self.room.localParticipant.identity?.stringValue ?? "nil")")
        }
    }
}
