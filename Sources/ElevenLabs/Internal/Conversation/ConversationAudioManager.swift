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
    }

    static func setRecordingAlwaysPreparedMode(_ enabled: Bool) async throws {
        try await AudioManager.shared.setRecordingAlwaysPreparedMode(enabled)
    }

    deinit {
        if audioSpeechHandlerInstalled {
            AudioManager.shared.onMutedSpeechActivity = previousSpeechActivityHandler
        }
    }

    // MARK: - Configuration

    /// Apply audio pipeline configuration from conversation config. In the mute modes that
    /// detect speech while muted, `onSpeechDetectedWhileMuted` runs for each detection.
    func configure(
        with config: ConversationConfig,
        onSpeechDetectedWhileMuted: @escaping @MainActor @Sendable () -> Void
    ) async {
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

        configureSpeechHandler(muteMode: muteMode, onSpeechDetectedWhileMuted: onSpeechDetectedWhileMuted)
        configureSoftwareMuteProcessor(muteMode: muteMode, onSpeechDetectedWhileMuted: onSpeechDetectedWhileMuted)
    }

    /// Cleanup audio state when conversation ends.
    func cleanup() {
        cleanupSpeechHandler()
        cleanupSoftwareMuteProcessor()
    }

    // MARK: - Private

    private func configureSpeechHandler(
        muteMode: MicrophoneMuteMode,
        onSpeechDetectedWhileMuted: @escaping @MainActor @Sendable () -> Void
    ) {
        if muteMode == .voiceProcessing {
            if !audioSpeechHandlerInstalled {
                previousSpeechActivityHandler = AudioManager.shared.onMutedSpeechActivity
                audioSpeechHandlerInstalled = true
            }
            // A handler that the app set on LiveKit itself keeps getting the events.
            let previousHandler = previousSpeechActivityHandler
            AudioManager.shared.onMutedSpeechActivity = { manager, event in
                previousHandler?(manager, event)
                guard event == .started else { return }
                Task { @MainActor in
                    onSpeechDetectedWhileMuted()
                }
            }
        } else if audioSpeechHandlerInstalled {
            cleanupSpeechHandler()
        }
    }

    private func configureSoftwareMuteProcessor(
        muteMode: MicrophoneMuteMode,
        onSpeechDetectedWhileMuted: @escaping @MainActor @Sendable () -> Void
    ) {
        guard case let .software(speechThreshold, notificationThrottle) = muteMode else {
            if softwareMuteProcessor != nil {
                cleanupSoftwareMuteProcessor()
            }
            return
        }

        softwareMuteProcessor = SoftwareMuteProcessor(
            onSpeechDetectedWhileMuted: onSpeechDetectedWhileMuted,
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
