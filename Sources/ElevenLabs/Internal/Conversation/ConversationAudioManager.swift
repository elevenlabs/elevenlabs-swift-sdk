import Foundation

#if canImport(LiveKit)
import LiveKit
#endif

@MainActor
final class RecordingPreparationCoordinator {
    static let shared = RecordingPreparationCoordinator()

    private var warmSessionCount = 0
    private var appliedMode: Bool?
    private var isApplying = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

    func configure(
        _ prepared: Bool,
        apply: @MainActor (Bool) async throws -> Void
    ) async throws {
        if prepared {
            warmSessionCount += 1
            do {
                try await reconcile(apply: apply)
            } catch {
                warmSessionCount -= 1
                throw error
            }
        } else {
            try await reconcile(apply: apply)
        }
    }

    func cleanup(
        _ prepared: Bool?,
        apply: @MainActor (Bool) async throws -> Void
    ) async throws {
        guard prepared == true, warmSessionCount > 0 else { return }
        warmSessionCount -= 1
        try await reconcile(apply: apply)
    }

    private func reconcile(
        apply: @MainActor (Bool) async throws -> Void
    ) async throws {
        while true {
            if isApplying {
                await withCheckedContinuation { transitionWaiters.append($0) }
                continue
            }

            let desiredMode = warmSessionCount > 0
            guard appliedMode != desiredMode else { return }

            isApplying = true
            do {
                try await apply(desiredMode)
                appliedMode = desiredMode
                finishTransition()
            } catch {
                finishTransition()
                throw error
            }
        }
    }

    private func finishTransition() {
        isApplying = false
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Manages audio device configuration and speech activity handling for conversations.
/// Encapsulates all AudioManager interactions to keep Conversation class focused on conversation logic.
@MainActor
final class ConversationAudioManager {
    private(set) var softwareMuteProcessor: SoftwareMuteProcessor?

    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private let logger: any Logging
    private let setRecordingAlwaysPreparedMode: @MainActor (Bool) async throws -> Void
    private let recordingPreparationCoordinator: RecordingPreparationCoordinator
    private var recordingAlwaysPrepared: Bool?

    init(
        logger: any Logging,
        recordingPreparationCoordinator: RecordingPreparationCoordinator = .shared,
        setRecordingAlwaysPreparedMode: @escaping @MainActor (Bool) async throws -> Void = {
            try await AudioManager.shared.setRecordingAlwaysPreparedMode($0)
        }
    ) {
        self.logger = logger
        self.recordingPreparationCoordinator = recordingPreparationCoordinator
        self.setRecordingAlwaysPreparedMode = setRecordingAlwaysPreparedMode
    }

    deinit {
        if audioSpeechHandlerInstalled {
            AudioManager.shared.onMutedSpeechActivity = previousSpeechActivityHandler
        }
    }

    // MARK: - Configuration

    /// Apply audio pipeline configuration from conversation config.
    func configure(with config: ConversationConfig, callbacks: ConversationCallbacks) async {
        let audioConfig = config.audioConfiguration ?? .default
        let muteMode = audioConfig.microphoneMuteMode ?? .inputMixer

        do {
            try AudioManager.shared.set(microphoneMuteMode: muteMode.toLiveKit())
        } catch {
            logger.warning("Failed to set microphone mute mode", context: ["error": "\(error)"])
        }

        if let bypass = audioConfig.voiceProcessingBypassed {
            AudioManager.shared.isVoiceProcessingBypassed = bypass
        }

        if let agc = audioConfig.voiceProcessingAGCEnabled {
            AudioManager.shared.isVoiceProcessingAGCEnabled = agc
        }

        if let prepared = audioConfig.recordingAlwaysPrepared {
            do {
                try await recordingPreparationCoordinator.configure(
                    prepared,
                    apply: setRecordingAlwaysPreparedMode
                )
                recordingAlwaysPrepared = prepared
            } catch {
                logger.warning("Failed to set recording always prepared mode", context: ["error": "\(error)"])
            }
        }

        configureSpeechHandler(muteMode: muteMode, callbacks: callbacks)
        configureSoftwareMuteProcessor(muteMode: muteMode, callbacks: callbacks)
    }

    /// Cleanup audio state when conversation ends.
    func cleanup() async {
        cleanupSpeechHandler()
        cleanupSoftwareMuteProcessor()
        let recordingAlwaysPrepared = recordingAlwaysPrepared
        self.recordingAlwaysPrepared = nil
        do {
            try await recordingPreparationCoordinator.cleanup(
                recordingAlwaysPrepared,
                apply: setRecordingAlwaysPreparedMode
            )
        } catch {
            logger.warning("Failed to disable recording always prepared mode", context: ["error": "\(error)"])
        }
    }

    // MARK: - Private

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
