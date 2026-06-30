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

    private var consecutiveAboveCount: Int = 0
    private var consecutiveBelowCount: Int = 0
    private var hangoverLatched: Bool = false

    private let onSpeakingWhileMutedChange: (@Sendable (Bool) -> Void)?
    private let mutedSpeechThresholdInDb: Float

    init(
        onSpeakingWhileMutedChange: (@Sendable (Bool) -> Void)?,
        mutedSpeechThresholdInDb: Float = -35
    ) {
        self.onSpeakingWhileMutedChange = onSpeakingWhileMutedChange
        self.mutedSpeechThresholdInDb = mutedSpeechThresholdInDb
    }

    /// The current software-gate mute state. The source of truth for
    /// `.software` mute mode, where the capture track stays open and the
    /// hardware mic flag would misleadingly read as unmuted.
    var muted: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return isMuted
    }

    func setMuted(_ muted: Bool) {
        var fireEnded = false
        os_unfair_lock_lock(&lock)
        if isMuted != muted {
            // Unmuting while speech was latched ends the muted-speech segment.
            if !muted, hangoverLatched {
                fireEnded = true
            }
            consecutiveAboveCount = 0
            consecutiveBelowCount = 0
            hangoverLatched = false
        }
        isMuted = muted
        os_unfair_lock_unlock(&lock)

        if fireEnded {
            DispatchQueue.main.async { self.onSpeakingWhileMutedChange?(false) }
        }
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        os_unfair_lock_lock(&lock)
        let currentlyMuted = isMuted
        os_unfair_lock_unlock(&lock)

        guard currentlyMuted else { return }

        let channelCount = audioBuffer.channels
        let frameCount = audioBuffer.frames
        let vCount = vDSP_Length(frameCount)

        // RMS is homogeneous (RMS(x/k) == RMS(x)/k), so we compute it on the raw
        // samples and scale the single scalar instead of normalizing the whole
        // buffer first. This avoids a heap allocation on the realtime audio thread.
        // `rawBuffer(forChannel:)` returns float samples in int16 range (±32768),
        // hence the 32768 divisor.
        var totalRMS: Float = 0
        for i in 0 ..< channelCount {
            let ptr = audioBuffer.rawBuffer(forChannel: i)
            var channelRMS: Float = 0
            vDSP_rmsqv(ptr, 1, &channelRMS, vCount)
            totalRMS += channelRMS / 32768.0
        }
        let averageRMS = totalRMS / Float(max(audioBuffer.channels, 1))
        let db = 20 * log10(max(averageRMS, 1e-6))

        let levelActive = db > mutedSpeechThresholdInDb

        var fireStarted = false
        var fireEnded = false
        os_unfair_lock_lock(&lock)
        if levelActive {
            consecutiveBelowCount = 0
            consecutiveAboveCount += 1
            if consecutiveAboveCount >= Hangover.buffersAboveToConfirm, !hangoverLatched {
                hangoverLatched = true
                fireStarted = true
            }
        } else {
            consecutiveAboveCount = 0
            consecutiveBelowCount += 1
            if consecutiveBelowCount >= Hangover.buffersBelowToClear, hangoverLatched {
                hangoverLatched = false
                consecutiveBelowCount = 0
                fireEnded = true
            }
        }
        os_unfair_lock_unlock(&lock)

        if fireStarted {
            DispatchQueue.main.async {
                self.onSpeakingWhileMutedChange?(true)
            }
        }
        if fireEnded {
            DispatchQueue.main.async {
                self.onSpeakingWhileMutedChange?(false)
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
