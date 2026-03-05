//
//  ConversationMutedSpeechDetector.swift
//  ElevenLabs
//
//  Created by Jackson Harper on 5/3/26.
//

import Accelerate
import CoreMedia
import LiveKit
import LiveKitWebRTC

final class ConversationMutedSpeechDetector: NSObject, @unchecked Sendable, AudioCustomProcessingDelegate {
    private var lock = os_unfair_lock_s()
    private var _isMuted: Bool = false
    private var _lastNotificationTime: Date = .distantPast

    private let onMutedSpeech: @Sendable (MutedSpeechEvent) -> Void
    private let mutedSpeechThresholdInDb: Float
    private let mutedSpeechThrottleInSeconds: TimeInterval

    init(
        onMutedSpeech: @escaping (@Sendable (MutedSpeechEvent) -> Void),
        mutedSpeechThresholdInDb: Float = -35,
        mutedSpeechThrottleInSeconds: TimeInterval = 3.0
    ) {
        self.onMutedSpeech = onMutedSpeech
        self.mutedSpeechThresholdInDb = mutedSpeechThresholdInDb
        self.mutedSpeechThrottleInSeconds = mutedSpeechThrottleInSeconds
    }

    func setMuted(_ muted: Bool) {
        os_unfair_lock_lock(&lock)
        _isMuted = muted
        os_unfair_lock_unlock(&lock)
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        os_unfair_lock_lock(&lock)
        let currentlyMuted = _isMuted
        let lastTime = _lastNotificationTime
        os_unfair_lock_unlock(&lock)

        guard currentlyMuted else { return }

        let channelCount = audioBuffer.channels
        let frameCount = audioBuffer.frames
        let vCount = vDSP_Length(frameCount)

        var totalRMS: Float = 0
        for i in 0 ..< audioBuffer.channels {
            let ptr = audioBuffer.rawBuffer(forChannel: i)
            var normalized = [Float](repeating: 0, count: frameCount)
            var divisor: Float = 32768.0
            vDSP_vsdiv(ptr, 1, &divisor, &normalized, 1, vCount)
            var channelRMS: Float = 0
            vDSP_rmsqv(normalized, 1, &channelRMS, vCount)
            totalRMS += channelRMS
        }
        let averageRMS = totalRMS / Float(max(audioBuffer.channels, 1))
        let db = 20 * log10(max(averageRMS, 1e-6))
        if db > mutedSpeechThresholdInDb {
            let now = Date()
            if now.timeIntervalSince(lastTime) > mutedSpeechThrottleInSeconds {
                os_unfair_lock_lock(&lock)
                _lastNotificationTime = now
                os_unfair_lock_unlock(&lock)
                DispatchQueue.main.async {
                    self.onMutedSpeech(.init(audioLevel: db))
                }
            }
        }

        let frameCountV = vDSP_Length(frameCount)
        for i in 0 ..< channelCount {
            let ptr = audioBuffer.rawBuffer(forChannel: i)
            vDSP_vclr(ptr, 1, frameCountV)
        }
    }

    func audioProcessingInitialize(sampleRate _: Int, channels _: Int) {}

    func audioProcessingRelease() {}
}
