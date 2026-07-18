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
    private(set) var softwareMuteProcessor: SoftwareMuteProcessor?

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

    /// Apply audio pipeline configuration from conversation config.
    func configure(with config: ConversationConfig, callbacks: ConversationCallbacks) async {
        let audioConfig = config.audioConfiguration
        let muteMode = audioConfig?.microphoneMuteMode ?? .inputMixer

        do {
            try audioManager.set(microphoneMuteMode: muteMode.toLiveKit())
        } catch {
            logger.warning("Failed to set microphone mute mode", context: ["error": "\(error)"])
        }

        if let bypass = audioConfig?.voiceProcessingBypassed {
            audioManager.isVoiceProcessingBypassed = bypass
        }

        if let agc = audioConfig?.voiceProcessingAGCEnabled {
            audioManager.isVoiceProcessingAGCEnabled = agc
        }

        if let prepared = audioConfig?.recordingAlwaysPrepared {
            do {
                try await audioManager.setRecordingAlwaysPreparedMode(prepared)
            } catch {
                logger.warning("Failed to set recording always prepared mode", context: ["error": "\(error)"])
            }
        }

        configureSpeechHandler(muteMode: muteMode, callbacks: callbacks)
        configureSoftwareMuteProcessor(muteMode: muteMode, callbacks: callbacks)
    }

    /// Cleanup audio state when conversation ends.
    func cleanup() {
        cleanupSpeechHandler()
        cleanupSoftwareMuteProcessor()
    }

    // MARK: - Private

    private func setupInitialConfiguration() {
        // Set initial microphone mute mode
        do {
            try audioManager.set(microphoneMuteMode: LiveKit.MicrophoneMuteMode.inputMixer)
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

    private func configureSpeechHandler(muteMode: MicrophoneMuteMode, callbacks: ConversationCallbacks) {
        if muteMode == .voiceProcessing, let onSpeechDetectedWhileMuted = callbacks.onSpeechDetectedWhileMuted {
            if !audioSpeechHandlerInstalled {
                previousSpeechActivityHandler = audioManager.onMutedSpeechActivity
                audioSpeechHandlerInstalled = true
            }
            audioManager.onMutedSpeechActivity = { _, event in
                Task { @MainActor in
                    if event == .started {
                        onSpeechDetectedWhileMuted()
                    }
                }
            }
        } else if audioSpeechHandlerInstalled {
            cleanupSpeechHandler()
        }
    }

    private func configureSoftwareMuteProcessor(muteMode: MicrophoneMuteMode, callbacks: ConversationCallbacks) {
        guard case let .software(speechThreshold, notificationThrottle) = muteMode else {
            if softwareMuteProcessor != nil {
                cleanupSoftwareMuteProcessor()
            }
            return
        }

        softwareMuteProcessor = SoftwareMuteProcessor(
            onSpeechDetectedWhileMuted: callbacks.onSpeechDetectedWhileMuted,
            mutedSpeechThresholdInDb: speechThreshold,
            mutedSpeechThrottleInSeconds: notificationThrottle
        )
        AudioManager.shared.capturePostProcessingDelegate = softwareMuteProcessor
    }

    private func cleanupSpeechHandler() {
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
    }

    private func cleanupSoftwareMuteProcessor() {
        AudioManager.shared.capturePostProcessingDelegate = nil
        softwareMuteProcessor = nil
    }
}

extension MicrophoneMuteMode {
    fileprivate func toLiveKit() -> LiveKit.MicrophoneMuteMode {
        switch self {
        case .inputMixer, .software:
            .inputMixer
        case .restart:
            .restart
        case .voiceProcessing:
            .voiceProcessing
        }
    }
}
