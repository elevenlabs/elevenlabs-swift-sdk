//
//  Input.swift
//  ElevenLabsSDK
//
//  Created by Mathew Gacy on 7/6/25.
//

import AVFoundation
import Foundation

final class Input {
    typealias ElevenLabsError = ElevenLabsSDK.ElevenLabsError

    let audioUnit: AudioUnit
    var audioFormat: AudioStreamBasicDescription
    var isRecording: Bool = false
    private var recordCallback: ((AVAudioPCMBuffer, Float) -> Void)?
    private var currentAudioLevel: Float = 0.0

    private init(audioUnit: AudioUnit, audioFormat: AudioStreamBasicDescription) {
        self.audioUnit = audioUnit
        self.audioFormat = audioFormat
    }

    static func create(sampleRate: Double) async throws -> Input {
        // Define the Audio Component
        var audioComponentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO, // For echo cancellation
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let audioComponent = AudioComponentFindNext(nil, &audioComponentDesc) else {
            throw ElevenLabsError.failedToCreateAudioComponent
        }

        var audioUnitOptional: AudioUnit?
        AudioComponentInstanceNew(audioComponent, &audioUnitOptional)
        guard let audioUnit = audioUnitOptional else {
            throw ElevenLabsError.failedToCreateAudioComponentInstance
        }

        // Create the Input instance
        let input = Input(audioUnit: audioUnit, audioFormat: AudioStreamBasicDescription())

        // Enable IO for recording
        var enableIO: UInt32 = 1
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             1,
                             &enableIO,
                             UInt32(MemoryLayout.size(ofValue: enableIO)))

        // Disable output
        var disableIO: UInt32 = 0
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             0,
                             &disableIO,
                             UInt32(MemoryLayout.size(ofValue: disableIO)))

        // Set the audio format
        var audioFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             1, // Bus 1 (Output scope of input element)
                             &audioFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        input.audioFormat = audioFormat

        // Set the input callback
        var inputCallbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(input).toOpaque())
        )
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global,
                             1, // Bus 1
                             &inputCallbackStruct,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // Initialize and start the audio unit
        AudioUnitInitialize(audioUnit)
        AudioOutputUnitStart(audioUnit)

        return input
    }

    func setRecordCallback(_ callback: @escaping (AVAudioPCMBuffer, Float) -> Void) {
        recordCallback = callback
    }

    func close() {
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }

    private static let inputRenderCallback: AURenderCallback = {
        inRefCon,
            ioActionFlags,
            inTimeStamp,
            _,
            inNumberFrames,
            _
            -> OSStatus in
        let input = Unmanaged<Input>.fromOpaque(inRefCon).takeUnretainedValue()
        let audioUnit = input.audioUnit

        let byteSize = Int(inNumberFrames) * MemoryLayout<Int16>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<Int16>.alignment)
        var audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteSize),
            mData: data
        )
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: audioBuffer
        )

        let status = AudioUnitRender(audioUnit,
                                     ioActionFlags,
                                     inTimeStamp,
                                     1, // inBusNumber
                                     inNumberFrames,
                                     &bufferList)

        if status == noErr {
            let frameCount = Int(inNumberFrames)
            guard let audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: input.audioFormat.mSampleRate,
                channels: 1,
                interleaved: true
            ) else {
                data.deallocate()
                return noErr
            }
            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                data.deallocate()
                return noErr
            }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            let dataPointer = data.assumingMemoryBound(to: Int16.self)
            if let channelData = pcmBuffer.int16ChannelData {
                memcpy(channelData[0], dataPointer, byteSize)
            }

            // Compute RMS value for volume level
            var rms: Float = 0.0
            for i in 0 ..< frameCount {
                let sample = Float(dataPointer[i]) / Float(Int16.max)
                rms += sample * sample
            }
            rms = sqrt(rms / Float(frameCount))

            // Call the callback with the audio buffer and current audio level
            input.recordCallback?(pcmBuffer, rms)
        }

        data.deallocate()
        return status
    }
}
