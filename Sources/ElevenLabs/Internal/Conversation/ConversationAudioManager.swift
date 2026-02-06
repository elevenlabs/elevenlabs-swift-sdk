import Foundation

#if canImport(LiveKit)
import LiveKit
#endif

/// Manages audio device configuration and speech activity handling for conversations.
/// Encapsulates all AudioManager interactions to keep Conversation class focused on conversation logic.
@MainActor
final class ConversationAudioManager {
    private(set) var audioDevices: [AudioDevice] = []
    private(set) var selectedAudioDeviceID: String = ""

    private let audioManager = AudioManager.shared
    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private let logger: any Logging

    /// Callback when audio devices list changes
    var onDevicesChanged: (([AudioDevice]) -> Void)?

    /// Callback when selected device changes
    var onSelectedDeviceChanged: ((String) -> Void)?

    init(logger: any Logging) {
        self.logger = logger
        audioDevices = audioManager.inputDevices
        selectedAudioDeviceID = audioManager.inputDevice.deviceId
        setupInitialConfiguration()
    }

    deinit {
        // Reset callbacks directly since we can't call MainActor methods from deinit
        audioManager.onDeviceUpdate = nil
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
        }
    }

    // MARK: - Configuration

    /// Apply audio pipeline configuration from conversation options.
    func configure(with options: ConversationOptions) async {
        let config = options.audioConfiguration

        if let mode = config?.microphoneMuteMode {
            do {
                try audioManager.set(microphoneMuteMode: mode)
            } catch {
                logger.warning("Failed to set microphone mute mode", context: ["error": "\(error)"])
            }
        }

        if let bypass = config?.voiceProcessingBypassed {
            audioManager.isVoiceProcessingBypassed = bypass
        }

        if let agc = config?.voiceProcessingAGCEnabled {
            audioManager.isVoiceProcessingAGCEnabled = agc
        }

        if let prepared = config?.recordingAlwaysPrepared {
            do {
                try await audioManager.setRecordingAlwaysPreparedMode(prepared)
            } catch {
                logger.warning("Failed to set recording always prepared mode", context: ["error": "\(error)"])
            }
        }

        configureSpeechHandler(options: options)
    }

    /// Cleanup audio state when conversation ends.
    func cleanup() {
        cleanupSpeechHandler()
    }

    // MARK: - Private

    private func setupInitialConfiguration() {
        // Set initial microphone mute mode
        do {
            try audioManager.set(microphoneMuteMode: .inputMixer)
        } catch {
            logger.warning("Failed to set initial microphone mute mode", context: ["error": "\(error)"])
        }

        // Set recording always prepared mode asynchronously
        Task { [weak self] in
            guard let self else { return }
            do {
                try await audioManager.setRecordingAlwaysPreparedMode(true)
            } catch {
                logger.warning("Failed to set recording always prepared mode", context: ["error": "\(error)"])
            }
        }

        // Setup device change observer
        audioManager.onDeviceUpdate = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audioDevices = self.audioManager.inputDevices
                self.selectedAudioDeviceID = self.audioManager.defaultInputDevice.deviceId
                self.onDevicesChanged?(self.audioDevices)
                self.onSelectedDeviceChanged?(self.selectedAudioDeviceID)
            }
        }
    }

    private func configureSpeechHandler(options: ConversationOptions) {
        let config = options.audioConfiguration
        let needsSpeechHandler = (config?.onSpeechActivity != nil) || (options.onSpeechActivity != nil)

        if needsSpeechHandler {
            if !audioSpeechHandlerInstalled {
                previousSpeechActivityHandler = audioManager.onMutedSpeechActivity
                audioSpeechHandlerInstalled = true
            }
            audioManager.onMutedSpeechActivity = { _, event in
                // Handlers are @Sendable, they manage their own synchronization
                if let handler = config?.onSpeechActivity {
                    handler(event)
                }
                if let handler = options.onSpeechActivity {
                    handler(event)
                }
            }
        } else if audioSpeechHandlerInstalled {
            cleanupSpeechHandler()
        }
    }

    private func cleanupSpeechHandler() {
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
    }
}
