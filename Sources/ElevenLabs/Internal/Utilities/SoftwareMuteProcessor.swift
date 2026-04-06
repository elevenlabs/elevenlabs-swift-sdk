//
//  SoftwareMuteProcessor.swift
//  ElevenLabs
//
//  Created by Jackson Harper on 5/3/26.
//

import Accelerate
import CoreMedia
import Foundation
import LiveKit
import LiveKitWebRTC

final class SoftwareMuteProcessor: NSObject, @unchecked Sendable, AudioCustomProcessingDelegate {
    private enum Hangover {
        static let buffersAboveToConfirm = 4
        static let buffersBelowToClear = 3
    }

    private var lock = os_unfair_lock_s()
    private var isMuted: Bool = false
    private var lastNotificationTime: Date = .distantPast

    private var consecutiveAboveCount: Int = 0
    private var consecutiveBelowCount: Int = 0
    private var hangoverLatched: Bool = false

    private let onMutedSpeech: (@Sendable (MutedSpeechEvent) -> Void)?
    private let mutedSpeechThresholdInDb: Float
    private let mutedSpeechThrottleInSeconds: TimeInterval

    init(
        onMutedSpeech: (@Sendable (MutedSpeechEvent) -> Void)?,
        mutedSpeechThresholdInDb: Float = -35,
        mutedSpeechThrottleInSeconds: TimeInterval = 3.0
    ) {
        self.onMutedSpeech = onMutedSpeech
        self.mutedSpeechThresholdInDb = mutedSpeechThresholdInDb
        self.mutedSpeechThrottleInSeconds = mutedSpeechThrottleInSeconds
    }

    func setMuted(_ muted: Bool) {
        os_unfair_lock_lock(&lock)
        if isMuted != muted {
            consecutiveAboveCount = 0
            consecutiveBelowCount = 0
            hangoverLatched = false
        }
        isMuted = muted
        os_unfair_lock_unlock(&lock)
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        os_unfair_lock_lock(&lock)
        let currentlyMuted = isMuted
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

        let levelActive = db > mutedSpeechThresholdInDb

        var shouldFire = false
        var fireLevel: Float = 0
        os_unfair_lock_lock(&lock)
        if levelActive {
            consecutiveBelowCount = 0
            consecutiveAboveCount += 1
            if consecutiveAboveCount >= Hangover.buffersAboveToConfirm {
                hangoverLatched = true
            }
        } else {
            consecutiveAboveCount = 0
            consecutiveBelowCount += 1
            if consecutiveBelowCount >= Hangover.buffersBelowToClear {
                hangoverLatched = false
                consecutiveBelowCount = 0
            }
        }

        if hangoverLatched, levelActive {
            let now = Date()
            if now.timeIntervalSince(lastNotificationTime) > mutedSpeechThrottleInSeconds {
                lastNotificationTime = now
                shouldFire = true
                fireLevel = db
            }
        }
        os_unfair_lock_unlock(&lock)

        if shouldFire {
            DispatchQueue.main.async {
                self.onMutedSpeech?(.init(audioLevel: fireLevel))
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
