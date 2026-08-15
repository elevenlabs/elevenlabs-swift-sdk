import Foundation

#if canImport(LiveKit)
import LiveKit
#endif

/// Manages audio device configuration and speech activity handling for conversations.
/// Encapsulates all AudioManager interactions to keep Conversation class focused on conversation logic.
@MainActor
final class ConversationAudioManager {
    private(set) var softwareMuteProcessor: SoftwareMuteProcessor?

    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private let logger: any Logging

    init(logger: any Logging) {
        self.logger = logger
        setupInitialConfiguration()
    }

    deinit {
        if audioSpeechHandlerInstalled {
            AudioManager.shared.onMutedSpeechActivity = previousSpeechActivityHandler
        }
    }

    // MARK: - Configuration

    /// Apply audio pipeline configuration from conversation config.
    func configure(with config: ConversationConfig, callbacks: ConversationCallbacks) async {
        let audioConfig = config.audioConfiguration
        let muteMode = audioConfig?.microphoneMuteMode ?? .inputMixer

        do {
            try AudioManager.shared.set(microphoneMuteMode: muteMode.toLiveKit())
        } catch {
            logger.warning("Failed to set microphone mute mode", context: ["error": "\(error)"])
        }

        if let bypass = audioConfig?.voiceProcessingBypassed {
            AudioManager.shared.isVoiceProcessingBypassed = bypass
        }

        if let agc = audioConfig?.voiceProcessingAGCEnabled {
            AudioManager.shared.isVoiceProcessingAGCEnabled = agc
        }

        if let prepared = audioConfig?.recordingAlwaysPrepared {
            do {
                try await AudioManager.shared.setRecordingAlwaysPreparedMode(prepared)
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
            try AudioManager.shared.set(microphoneMuteMode: LiveKit.MicrophoneMuteMode.inputMixer)
        } catch {
            logger.warning("Failed to set initial microphone mute mode", context: ["error": "\(error)"])
        }

        // Set recording always prepared mode asynchronously
        Task { [weak self] in
            guard let self else { return }
            do {
                try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
            } catch {
                logger.warning("Failed to set recording always prepared mode", context: ["error": "\(error)"])
            }
        }
    }

    private func configureSpeechHandler(muteMode: MicrophoneMuteMode, callbacks: ConversationCallbacks) {
        if muteMode == .voiceProcessing, let onSpeechDetectedWhileMuted = callbacks.onSpeechDetectedWhileMuted {
            if !audioSpeechHandlerInstalled {
                previousSpeechActivityHandler = AudioManager.shared.onMutedSpeechActivity
                audioSpeechHandlerInstalled = true
            }
            AudioManager.shared.onMutedSpeechActivity = { _, event in
                guard event == .started else { return }
                Task { @MainActor in
                    onSpeechDetectedWhileMuted()
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
            AudioManager.shared.onMutedSpeechActivity = previousSpeechActivityHandler
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
