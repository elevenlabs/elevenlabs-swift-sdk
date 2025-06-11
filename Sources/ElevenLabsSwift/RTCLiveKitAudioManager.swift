import LiveKit
import AVFoundation
import Foundation
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
        // Create microphone track with enhanced audio options
        let audioOptions = AudioCaptureOptions(
            echoCancellation: true,
            autoGainControl: true,
            noiseSuppression: true,
            typingNoiseDetection: true
        )
        
        localAudioTrack = LocalAudioTrack.createTrack(options: audioOptions)
        
        // Publish microphone track
        localAudioPublication = try await room.localParticipant.publish(audioTrack: localAudioTrack!)
        logger.info("Microphone track published: \(self.localAudioPublication!.sid)")
        
        // Start volume monitoring
        startVolumeMonitoring()
    }
    
    private func setupAudioEventHandlers() {
        room.add(delegate: self)
    }
    
    private func startVolumeMonitoring() {
        // Input volume monitoring
        volumeMonitor = Timer.scheduledTimer(withTimeInterval: ElevenLabsSDK.Constants.volumeUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.isMicrophoneEnabled {
                self.getInputVolumeLevel { volume in
                    DispatchQueue.main.async {
                        self.callbacks.onVolumeUpdate(volume)
                    }
                }
            }
        }
    }
    
    private func startOutputVolumeMonitoring() {
        // Output volume monitoring for agent audio
        outputVolumeMonitor = Timer.scheduledTimer(withTimeInterval: ElevenLabsSDK.Constants.volumeUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.remoteAudioTrack != nil else { return }
            
            self.getOutputVolumeLevel { volume in
                DispatchQueue.main.async {
                    self.callbacks.onOutputVolumeUpdate(volume)
                }
            }
        }
    }
    
    private func getInputVolumeLevel(completion: @escaping (Float) -> Void) {
        // Get actual audio levels from the local audio track
        // This is a simplified implementation - in production you'd use WebRTC stats
        guard localAudioTrack != nil else {
            completion(0.0)
            return
        }
        
        // For now, return a simulated value
        // In a real implementation, you would use RTCStatistics or audio level monitoring
        let simulatedLevel = Float.random(in: 0.0...0.8)
        completion(simulatedLevel)
    }

    private func getOutputVolumeLevel(completion: @escaping (Float) -> Void) {
        // Get actual audio levels from the remote audio track
        guard remoteAudioTrack != nil else {
            completion(0.0)
            return
        }
        
        // For now, return a simulated value
        // In a real implementation, you would use RTCStatistics or audio level monitoring
        let simulatedLevel = Float.random(in: 0.0...1.0)
        completion(simulatedLevel)
    }
    
    func setMicrophoneEnabled(_ enabled: Bool) {
        isMicrophoneEnabled = enabled
        Task {
            if enabled {
                try await localAudioTrack?.unmute()
            } else {
                try await localAudioTrack?.mute()
            }
        }
        logger.debug("Microphone enabled: \(enabled)")
    }
    
    func setVolume(_ volume: Float) {
        self.volume = max(0, min(1, volume))
        // Note: WebRTC/LiveKit handles audio volume automatically
        // For custom volume control, you'd need to implement audio processing
        logger.debug("Volume set to: \(self.volume)")
    }
    
    func close() async {
        volumeMonitor?.invalidate()
        volumeMonitor = nil
        
        outputVolumeMonitor?.invalidate()
        outputVolumeMonitor = nil
        
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

// MARK: - Room Delegate
@available(macOS 11.0, iOS 14.0, *)
extension RTCLiveKitAudioManager: RoomDelegate {
    public func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: TrackPublication, track: Track) {
        if let audioTrack = track as? RemoteAudioTrack, 
           let identity = participant.identity, 
           identity.stringValue.contains("agent") {
            remoteAudioTrack = audioTrack
            attachRemoteAudio(audioTrack)
            logger.info("Agent audio track subscribed: \(publication.sid)")
        }
    }
    
    public func room(_ room: Room, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool, participant: Participant?) {
        if let participant = participant as? RemoteParticipant,
        let identity = participant.identity,
        identity.stringValue.contains("agent"),
        trackPublication.track == remoteAudioTrack {
            
            // Update mode based on agent audio activity
            let newMode: ElevenLabsSDK.Mode = isMuted ? .listening : .speaking
            callbacks.onModeChange(newMode)
            let modeString = newMode == .listening ? "listening" : "speaking"
            logger.debug("Agent audio muted state changed: \(isMuted), mode: \(modeString)")
        }
    }
    
    private func attachRemoteAudio(_ track: RemoteAudioTrack) {
        // Audio is automatically routed by WebRTC/LiveKit
        // Start monitoring output volume levels
        startOutputVolumeMonitoring()
        logger.info("Remote audio track attached")
    }
} 