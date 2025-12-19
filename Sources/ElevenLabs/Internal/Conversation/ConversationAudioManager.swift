import Foundation
import LiveKit

@MainActor
final class ConversationAudioManager: ObservableObject {
    @Published private(set) var audioDevices: [AudioDevice] = []
    @Published private(set) var selectedAudioDeviceID: String = ""
    
    private let audioManager = AudioManager.shared
    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private let logger: any Logging = SDKLogger(logLevel: ElevenLabs.Global.shared.configuration.logLevel)
    
    init() {
        audioDevices = audioManager.inputDevices
        selectedAudioDeviceID = audioManager.inputDevice.deviceId
        observeDeviceChanges()
    }
    
    deinit {
        audioManager.onDeviceUpdate = nil
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
        }
    }
    
    func configure(with options: ConversationOptions) async {
        let config = options.audioConfiguration
        
        if let mode = config?.microphoneMuteMode {
            try? audioManager.set(microphoneMuteMode: mode)
        }
        
        if let prepared = config?.recordingAlwaysPrepared {
            try? await audioManager.setRecordingAlwaysPreparedMode(prepared)
        }
        
        if let bypass = config?.voiceProcessingBypassed {
            audioManager.isVoiceProcessingBypassed = bypass
        }
        
        if let agc = config?.voiceProcessingAGCEnabled {
            audioManager.isVoiceProcessingAGCEnabled = agc
        }
        
        let needsSpeechHandler = (config?.onSpeechActivity != nil) || (options.onSpeechActivity != nil)
        
        if needsSpeechHandler {
            if !audioSpeechHandlerInstalled {
                previousSpeechActivityHandler = audioManager.onMutedSpeechActivity
                audioSpeechHandlerInstalled = true
            }
            audioManager.onMutedSpeechActivity = { _, event in
                // Handlers are @Sendable, they manage their own synchronization
                if let handler = options.audioConfiguration?.onSpeechActivity {
                    handler(event)
                }
                if let handler = options.onSpeechActivity {
                    handler(event)
                }
            }
        } else if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
    }
    
    func cleanup() {
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
    }
    
    private func observeDeviceChanges() {
        do {
            try audioManager.set(microphoneMuteMode: .inputMixer)
        } catch {
            logger.error("Failed to set microphone mute mode: \(error.localizedDescription)")
            // ignore
        }
        
        Task {
            do {
                try await audioManager.setRecordingAlwaysPreparedMode(true)
            } catch {
                // ignore
            }
        }
        
        audioManager.onDeviceUpdate = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audioDevices = self.audioManager.inputDevices
                self.selectedAudioDeviceID = self.audioManager.defaultInputDevice.deviceId
            }
        }
    }
}
