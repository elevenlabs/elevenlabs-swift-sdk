import AVFoundation
import Foundation
import LiveKit
import os.log

@available(macOS 11.0, iOS 14.0, *)
public class RTCLiveKitAudioManager: @unchecked Sendable {
    private let room: Room
    private let callbacks: ElevenLabsSDK.Callbacks
    private var localAudioTrack: LocalAudioTrack?
    private var localAudioPublication: TrackPublication?
    private var remoteAudioTrack: RemoteAudioTrack?
    private var volumeMonitor: Timer?
    private var outputVolumeMonitor: Timer?

    private let volumeLock = NSLock()
    private var _volume: Float = 1.0
    private var _isMicrophoneEnabled: Bool = true
    private var _lastInputLevel: Float = 0.0
    private var _lastOutputLevel: Float = 0.0
    private var _inputLevelHistory: [Float] = []
    private var _outputLevelHistory: [Float] = []

    // Audio processing for real-time level monitoring
    private var inputAudioRenderer: InputAudioRenderer?
    private var outputAudioRenderer: OutputAudioRenderer?

    private let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "RTCAudioManager")

    var volume: Float {
        get { volumeLock.withLock { _volume } }
        set { volumeLock.withLock { _volume = newValue } }
    }

    var isMicrophoneEnabled: Bool {
        get { volumeLock.withLock { _isMicrophoneEnabled } }
        set { volumeLock.withLock { _isMicrophoneEnabled = newValue } }
    }

    init(room: Room, callbacks: ElevenLabsSDK.Callbacks) {
        self.room = room
        self.callbacks = callbacks
        setupAudioEventHandlers()
    }

    func initialize() async throws {
        // Wait for room to be ready before enabling microphone
        var retries = 0
        while room.connectionState != .connected {
            if retries > 10 {
                throw ElevenLabsSDK.ElevenLabsError.connectionFailed("Room not connected after retries")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            retries += 1
        }

        // Enable microphone at participant level (this is the key fix)
        try await room.localParticipant.setMicrophone(enabled: true)

        // Get the local audio track that was created by setMicrophone
        localAudioTrack = room.localParticipant.firstAudioTrack as? LocalAudioTrack
        localAudioPublication = room.localParticipant.audioTracks.first

        guard let localTrack = localAudioTrack else {
            logger.error("Failed to get local audio track after enabling microphone")
            throw ElevenLabsSDK.ElevenLabsError.failedToCreateAudioComponent
        }

        // Set up real-time audio level monitoring for input
        inputAudioRenderer = InputAudioRenderer { [weak self] level in
            self?.updateInputLevel(level)
        }
        localTrack.add(audioRenderer: inputAudioRenderer!)

        logger.info("Microphone enabled and track ready: \(localAudioPublication?.sid.stringValue ?? "unknown")")

        // Start volume monitoring (now using real audio data)
        startVolumeMonitoring()
    }

    private func setupAudioEventHandlers() {
        room.add(delegate: self)
    }

    private func startVolumeMonitoring() {
        // Input volume monitoring for user microphone
        volumeMonitor = Timer.scheduledTimer(withTimeInterval: ElevenLabsSDK.Constants.volumeUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let currentLevel = self.getCurrentInputLevel()
            DispatchQueue.main.async {
                self.callbacks.onVolumeUpdate(currentLevel)
            }
        }
    }

    private func startOutputVolumeMonitoring() {
        // Output volume monitoring for agent audio
        outputVolumeMonitor = Timer.scheduledTimer(withTimeInterval: ElevenLabsSDK.Constants.volumeUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let currentLevel = self.getCurrentOutputLevel()
            DispatchQueue.main.async {
                self.callbacks.onOutputVolumeUpdate(currentLevel)
            }
        }
    }

    private func updateInputLevel(_ level: Float) {
        volumeLock.withLock {
            _lastInputLevel = level
            _inputLevelHistory.append(level)
            if _inputLevelHistory.count > 10 {
                _inputLevelHistory.removeFirst()
            }
        }
    }

    private func updateOutputLevel(_ level: Float) {
        volumeLock.withLock {
            _lastOutputLevel = level
            _outputLevelHistory.append(level)
            if _outputLevelHistory.count > 10 {
                _outputLevelHistory.removeFirst()
            }
        }
    }

    private func getInputVolumeLevel(completion: @escaping (Float) -> Void) {
        // Get input audio levels from the local audio track
        guard localAudioTrack != nil, isMicrophoneEnabled else {
            volumeLock.withLock { _lastInputLevel = 0.0 }
            completion(0.0)
            return
        }

        // Return the real-time audio level from the audio renderer
        let currentLevel = volumeLock.withLock { _lastInputLevel }
        completion(currentLevel)
    }

    private func getOutputVolumeLevel(completion: @escaping (Float) -> Void) {
        // Get output audio levels from the remote audio track (agent)
        guard remoteAudioTrack != nil else {
            volumeLock.withLock { _lastOutputLevel = 0.0 }
            completion(0.0)
            return
        }

        // Return the real-time audio level from the audio renderer
        let currentLevel = volumeLock.withLock { _lastOutputLevel }
        completion(currentLevel)
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        isMicrophoneEnabled = enabled
        Task {
            do {
                try await room.localParticipant.setMicrophone(enabled: enabled)
                logger.debug("Microphone enabled: \(enabled)")

                // Reset input level when microphone state changes
                volumeLock.withLock {
                    if !enabled {
                        _lastInputLevel = 0.0
                    }
                    _inputLevelHistory.removeAll()
                }
            } catch {
                logger.error("Failed to set microphone enabled: \(error.localizedDescription)")
            }
        }
    }

    func setVolume(_ volume: Float) {
        self.volume = max(0, min(1, volume))
        // Note: WebRTC/LiveKit handles audio volume automatically
        // For custom volume control, you'd need to implement audio processing
        logger.debug("Volume set to: \(self.volume)")
    }

    /// Get current input (user) volume level
    /// - Returns: Current input audio level (0.0 to 1.0)
    func getCurrentInputLevel() -> Float {
        return volumeLock.withLock { _lastInputLevel }
    }

    /// Get current output (agent) volume level
    /// - Returns: Current output audio level (0.0 to 1.0)
    func getCurrentOutputLevel() -> Float {
        return volumeLock.withLock { _lastOutputLevel }
    }

    /// Get recent input level history for trend analysis
    /// - Returns: Array of recent input levels (newest last)
    func getInputLevelHistory() -> [Float] {
        return volumeLock.withLock { Array(_inputLevelHistory) }
    }

    /// Get recent output level history for trend analysis
    /// - Returns: Array of recent output levels (newest last)
    func getOutputLevelHistory() -> [Float] {
        return volumeLock.withLock { Array(_outputLevelHistory) }
    }

    func close() async {
        volumeMonitor?.invalidate()
        volumeMonitor = nil

        outputVolumeMonitor?.invalidate()
        outputVolumeMonitor = nil

        // Remove audio renderers
        if let localTrack = localAudioTrack, let inputRenderer = inputAudioRenderer {
            localTrack.remove(audioRenderer: inputRenderer)
        }
        if let remoteTrack = remoteAudioTrack, let outputRenderer = outputAudioRenderer {
            remoteTrack.remove(audioRenderer: outputRenderer)
        }

        inputAudioRenderer = nil
        outputAudioRenderer = nil

        // Reset audio levels
        volumeLock.withLock {
            _lastInputLevel = 0.0
            _lastOutputLevel = 0.0
            _inputLevelHistory.removeAll()
            _outputLevelHistory.removeAll()
        }

        do {
            try await localAudioTrack?.stop()
        } catch {
            logger.error("Error stopping local audio track: \(error.localizedDescription)")
        }
        localAudioTrack = nil
        remoteAudioTrack = nil

        logger.info("Audio manager closed")
    }
}

// MARK: - Audio Renderers for Real-time Level Monitoring

@available(macOS 11.0, iOS 14.0, *)
private final class InputAudioRenderer: @unchecked Sendable, AudioRenderer {
    private let onLevelUpdate: @Sendable (Float) -> Void
    private let smoothingFactor: Float = 0.25
    private let lock = NSLock()
    private var _lastLevel: Float = 0.0

    private var lastLevel: Float {
        get { lock.withLock { _lastLevel } }
        set { lock.withLock { _lastLevel = newValue } }
    }

    init(onLevelUpdate: @escaping @Sendable (Float) -> Void) {
        self.onLevelUpdate = onLevelUpdate
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        // Calculate RMS (Root Mean Square) level from PCM data
        let rmsLevel = calculateRMSLevel(from: pcmBuffer)

        // Apply smoothing to avoid jarring level changes
        let smoothedLevel = (lastLevel * (1.0 - smoothingFactor)) + (rmsLevel * smoothingFactor)
        lastLevel = smoothedLevel

        // Normalize to 0.0-1.0 range and update
        let normalizedLevel = min(max(smoothedLevel, 0.0), 1.0)
        onLevelUpdate(normalizedLevel)
    }

    private func calculateRMSLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0
        else {
            return 0.0
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var rms: Float = 0.0

        // Calculate RMS for all channels
        for channel in 0 ..< channelCount {
            let samples = channelData[channel]
            var sum: Float = 0.0

            for frame in 0 ..< frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }

            rms += sum / Float(frameLength)
        }

        // Average across channels and take square root
        rms = sqrt(rms / Float(channelCount))

        // Convert to decibels and normalize
        let dbLevel = 20.0 * log10(max(rms, 1e-10)) // Avoid log(0)
        let normalizedLevel = max((dbLevel + 60.0) / 60.0, 0.0) // Normalize -60dB to 0dB range

        return normalizedLevel
    }
}

@available(macOS 11.0, iOS 14.0, *)
private final class OutputAudioRenderer: @unchecked Sendable, AudioRenderer {
    private let onLevelUpdate: @Sendable (Float) -> Void
    private let smoothingFactor: Float = 0.25
    private let lock = NSLock()
    private var _lastLevel: Float = 0.0

    private var lastLevel: Float {
        get { lock.withLock { _lastLevel } }
        set { lock.withLock { _lastLevel = newValue } }
    }

    init(onLevelUpdate: @escaping @Sendable (Float) -> Void) {
        self.onLevelUpdate = onLevelUpdate
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        // Calculate RMS (Root Mean Square) level from PCM data
        let rmsLevel = calculateRMSLevel(from: pcmBuffer)

        // Apply smoothing to avoid jarring level changes
        let smoothedLevel = (lastLevel * (1.0 - smoothingFactor)) + (rmsLevel * smoothingFactor)
        lastLevel = smoothedLevel

        // Normalize to 0.0-1.0 range and update
        let normalizedLevel = min(max(smoothedLevel, 0.0), 1.0)
        onLevelUpdate(normalizedLevel)
    }

    private func calculateRMSLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0
        else {
            return 0.0
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var rms: Float = 0.0

        // Calculate RMS for all channels
        for channel in 0 ..< channelCount {
            let samples = channelData[channel]
            var sum: Float = 0.0

            for frame in 0 ..< frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }

            rms += sum / Float(frameLength)
        }

        // Average across channels and take square root
        rms = sqrt(rms / Float(channelCount))

        // Convert to decibels and normalize
        let dbLevel = 20.0 * log10(max(rms, 1e-10)) // Avoid log(0)
        let normalizedLevel = max((dbLevel + 60.0) / 60.0, 0.0) // Normalize -60dB to 0dB range

        return normalizedLevel
    }
}

// MARK: - Room Delegate

@available(macOS 11.0, iOS 14.0, *)
extension RTCLiveKitAudioManager: RoomDelegate {
    public func room(_: Room, participant: RemoteParticipant, didSubscribe publication: TrackPublication, track: Track) {
        if let audioTrack = track as? RemoteAudioTrack,
           let identity = participant.identity,
           identity.stringValue.contains("agent")
        {
            remoteAudioTrack = audioTrack
            attachRemoteAudio(audioTrack)
            logger.info("Agent audio track subscribed: \(publication.sid.stringValue)")

            // Remote audio tracks are automatically controlled by LiveKit
            logger.info("Agent audio track ready to play")
        }
    }

    public func room(_: Room, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool, participant: Participant?) {
        if let participant = participant as? RemoteParticipant,
           let identity = participant.identity,
           identity.stringValue.contains("agent"),
           trackPublication.track == remoteAudioTrack
        {
            // Update mode based on agent audio activity
            let newMode: ElevenLabsSDK.Mode = isMuted ? .listening : .speaking
            callbacks.onModeChange(newMode)
            let modeString = newMode == .listening ? "listening" : "speaking"
            logger.debug("Agent audio muted state changed: \(isMuted), mode: \(modeString)")

            // Reset output level when mute state changes
            volumeLock.withLock {
                if isMuted {
                    _lastOutputLevel = 0.0
                }
                _outputLevelHistory.removeAll()
            }
        }
    }

    private func attachRemoteAudio(_ audioTrack: RemoteAudioTrack) {
        // Set up real-time audio level monitoring for output
        outputAudioRenderer = OutputAudioRenderer { [weak self] level in
            self?.updateOutputLevel(level)
        }
        audioTrack.add(audioRenderer: outputAudioRenderer!)

        // Audio is automatically routed by WebRTC/LiveKit
        // Start monitoring output volume levels
        startOutputVolumeMonitoring()
        logger.info("Remote audio track attached with real-time level monitoring")
    }
}
