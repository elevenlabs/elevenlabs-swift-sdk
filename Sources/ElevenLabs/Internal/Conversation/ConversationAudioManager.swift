import Foundation

#if canImport(LiveKit)
import LiveKit
#endif

/// Owns this conversation's `AudioManager.shared` configuration (mute mode, voice
/// processing, capture pre-warm) and speech-activity handling, keeping
/// `Conversation` focused on conversation logic.
@MainActor
final class ConversationAudioManager {
    private(set) var softwareMuteProcessor: SoftwareMuteProcessor?

    private let audioManager = AudioManager.shared
    private var previousSpeechActivityHandler: AudioManager.OnSpeechActivity?
    private var audioSpeechHandlerInstalled = false
    private let logger: any Logging

    // Snapshots of process-global `AudioManager.shared` state this instance
    // overwrote in `configure`, so `cleanup`/`deinit` can restore it instead of
    // leaking settings across sessions or clobbering the host app's values. A
    // `nil` entry means this instance never changed that setting.
    //
    // `previousCaptureDelegate` is only meaningful while `softwareMuteProcessor`
    // is non-nil.
    private var previousCaptureDelegate: AudioCustomProcessingDelegate?
    private var previousVoiceProcessingBypassed: Bool?
    private var previousVoiceProcessingAGCEnabled: Bool?

    init(logger: any Logging) {
        self.logger = logger
    }

    deinit {
        // Best-effort restore if torn down without a clean `cleanup()`. We can't
        // call MainActor methods here, but these `AudioManager.shared` accessors
        // are safe off the main actor.
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
        }
        // Only revert the capture delegate if ours is still the installed one; a
        // process-wide last-write-wins slot means something else may have taken
        // over after us, and we must not stomp that.
        if let processor = softwareMuteProcessor,
           audioManager.capturePostProcessingDelegate.map({ $0 as AnyObject }) === processor
        {
            audioManager.capturePostProcessingDelegate = previousCaptureDelegate
        }
        if let bypass = previousVoiceProcessingBypassed {
            audioManager.isVoiceProcessingBypassed = bypass
        }
        if let agc = previousVoiceProcessingAGCEnabled {
            audioManager.isVoiceProcessingAGCEnabled = agc
        }
    }

    // MARK: - Configuration

    /// Apply audio pipeline configuration from conversation options.
    ///
    /// This is the single configuration entry point: it establishes the baseline
    /// device state (mute mode + engine pre-warm) and applies any caller overrides.
    func configure(
        with config: ConversationConfig,
        onSpeakingWhileMutedChange: @escaping @Sendable (Bool) -> Void
    ) async {
        let audioConfig = config.audioConfiguration
        let muteMode = audioConfig?.microphoneMuteMode ?? .inputMixer

        do {
            try audioManager.set(microphoneMuteMode: muteMode.toLiveKit())
        } catch {
            logger.warning("Failed to set microphone mute mode", context: ["error": "\(error)"])
        }

        // Snapshot before overwriting so `cleanup` can restore the prior value
        // rather than leaking our override into later sessions / other consumers.
        if let bypass = audioConfig?.voiceProcessingBypassed {
            previousVoiceProcessingBypassed = audioManager.isVoiceProcessingBypassed
            audioManager.isVoiceProcessingBypassed = bypass
        }

        if let agc = audioConfig?.voiceProcessingAGCEnabled {
            previousVoiceProcessingAGCEnabled = audioManager.isVoiceProcessingAGCEnabled
            audioManager.isVoiceProcessingAGCEnabled = agc
        }

        // Pre-warm the capture engine via "recording always prepared" mode so the
        // first `setMicrophone(enabled:)` reuses a warm engine. Without it the
        // engine cold-starts at publish time and the first VPIO init fails with
        // audio-engine error -4010 (reproducible on the simulator after a fresh
        // permission grant).
        //
        // Intentionally NOT reverted in `cleanup`: keeping it prepared lets
        // back-to-back conversations reuse the warm engine, and is a benign global.
        do {
            try await audioManager.setRecordingAlwaysPreparedMode(true)
        } catch {
            logger.warning("Failed to set recording always prepared mode", context: ["error": "\(error)"])
        }

        configureSpeechHandler(onSpeakingWhileMutedChange: onSpeakingWhileMutedChange)
        configureSoftwareMuteProcessor(muteMode: muteMode, onSpeakingWhileMutedChange: onSpeakingWhileMutedChange)
    }

    /// Cleanup audio state when conversation ends.
    func cleanup() {
        cleanupSpeechHandler()
        cleanupSoftwareMuteProcessor()
        restoreVoiceProcessingState()
    }

    // MARK: - Private

    private func configureSpeechHandler(onSpeakingWhileMutedChange: @escaping @Sendable (Bool) -> Void) {
        if !audioSpeechHandlerInstalled {
            previousSpeechActivityHandler = audioManager.onMutedSpeechActivity
            audioSpeechHandlerInstalled = true
        }
        audioManager.onMutedSpeechActivity = { _, event in
            // Handlers are @Sendable, they manage their own synchronization.
            onSpeakingWhileMutedChange(event == .started)
        }
    }

    private func configureSoftwareMuteProcessor(
        muteMode: MicrophoneMuteMode,
        onSpeakingWhileMutedChange: @escaping @Sendable (Bool) -> Void
    ) {
        guard case let .software(speechThreshold) = muteMode else {
            return
        }

        let processor = SoftwareMuteProcessor(
            onSpeakingWhileMutedChange: onSpeakingWhileMutedChange,
            mutedSpeechThresholdInDb: speechThreshold
        )
        softwareMuteProcessor = processor
        // Snapshot any pre-existing delegate so `cleanup` restores it rather than
        // nilling out a delegate this instance never owned.
        previousCaptureDelegate = audioManager.capturePostProcessingDelegate
        audioManager.capturePostProcessingDelegate = processor
    }

    private func cleanupSpeechHandler() {
        if audioSpeechHandlerInstalled {
            audioManager.onMutedSpeechActivity = previousSpeechActivityHandler
            previousSpeechActivityHandler = nil
            audioSpeechHandlerInstalled = false
        }
    }

    private func cleanupSoftwareMuteProcessor() {
        guard let processor = softwareMuteProcessor else { return }
        // Restore the delegate we displaced — but only if ours is still the one
        // installed. The slot is process-wide last-write-wins, so if another
        // component set its own delegate after us, leave that in place.
        if audioManager.capturePostProcessingDelegate.map({ $0 as AnyObject }) === processor {
            audioManager.capturePostProcessingDelegate = previousCaptureDelegate
        }
        previousCaptureDelegate = nil
        softwareMuteProcessor = nil
    }

    /// Restore the VPIO flags this instance overrode in `configure`. The capture
    /// pre-warm (`setRecordingAlwaysPreparedMode(true)`) is intentionally left
    /// enabled process-wide (see `configure`), so it is not restored here.
    private func restoreVoiceProcessingState() {
        if let bypass = previousVoiceProcessingBypassed {
            audioManager.isVoiceProcessingBypassed = bypass
            previousVoiceProcessingBypassed = nil
        }
        if let agc = previousVoiceProcessingAGCEnabled {
            audioManager.isVoiceProcessingAGCEnabled = agc
            previousVoiceProcessingAGCEnabled = nil
        }
    }
}

// MARK: - LiveKit mapping

private extension MicrophoneMuteMode {
    /// Maps to LiveKit's hardware mute mode. Software mute has no LiveKit
    /// equivalent — the track is kept open and muting happens in
    /// `SoftwareMuteProcessor`, so the engine runs with `.inputMixer` underneath.
    func toLiveKit() -> LiveKit.MicrophoneMuteMode {
        switch self {
        case .voiceProcessing: .voiceProcessing
        case .restart: .restart
        case .inputMixer, .software: .inputMixer
        }
    }
}

