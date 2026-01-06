import Foundation
import LiveKit

@MainActor
final class ConversationAudioManager {
    private(set) var audioDevices: [AudioDevice] = []
    private(set) var selectedAudioDeviceID: String = ""
    private var devicesContinuation: AsyncStream<[AudioDevice]>.Continuation?
    private var selectedDeviceContinuation: AsyncStream<String>.Continuation?

    private let audioManager = AudioManager.shared
    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private let logger: any Logging = SDKLogger(logLevel: ElevenLabs.Global.shared.configuration.logLevel)

    init() {
        audioDevices = audioManager.inputDevices
        selectedAudioDeviceID = audioManager.inputDevice.deviceId
        setupAudioConfiguration()
    }

    deinit {
        audioManager.onDeviceUpdate = nil
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
        }
        devicesContinuation?.finish()
        selectedDeviceContinuation?.finish()
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

    private func setupAudioConfiguration() {
        do {
            try audioManager.set(microphoneMuteMode: .inputMixer)
        } catch {
            logger.error("Failed to set microphone mute mode: \(error.localizedDescription)")
        }

        Task {
            do {
                try await audioManager.setRecordingAlwaysPreparedMode(true)
            } catch {
                logger.error("Failed to set recording always prepared mode: \(error.localizedDescription)")
            }
        }

        setupDeviceChangeObserver()
    }

    private func setupDeviceChangeObserver() {
        audioManager.onDeviceUpdate = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Update audio devices list and default device when system notifies us of changes
                self.audioDevices = self.audioManager.inputDevices
                self.selectedAudioDeviceID = self.audioManager.defaultInputDevice.deviceId
                self.devicesContinuation?.yield(self.audioDevices)
                self.selectedDeviceContinuation?.yield(self.selectedAudioDeviceID)
            }
        }
    }

    func devicesUpdates() -> AsyncStream<[AudioDevice]> {
        AsyncStream { continuation in
            devicesContinuation = continuation
            continuation.yield(audioDevices)
        }
    }

    func selectedDeviceIdUpdates() -> AsyncStream<String> {
        AsyncStream { continuation in
            selectedDeviceContinuation = continuation
            continuation.yield(selectedAudioDeviceID)
        }
    }
}
