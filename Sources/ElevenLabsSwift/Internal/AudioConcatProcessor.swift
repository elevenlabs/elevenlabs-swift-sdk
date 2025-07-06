//
//  AudioConcatProcessor.swift
//  ElevenLabsSDK
//
//  Created by Mathew Gacy on 7/6/25.
//

import Foundation

final class AudioConcatProcessor {
    private var buffers: [Data] = []
    private var cursor: Int = 0
    private var currentBuffer: Data?
    private var wasInterrupted: Bool = false
    private var finished: Bool = false
    var onProcess: (@Sendable (Bool) -> Void)?

    func process(outputs: inout [[Float]]) {
        var isFinished = false
        let outputChannel = 0
        var outputBuffer = outputs[outputChannel]
        var outputIndex = 0

        while outputIndex < outputBuffer.count {
            if currentBuffer == nil {
                if buffers.isEmpty {
                    isFinished = true
                    break
                }
                currentBuffer = buffers.removeFirst()
                cursor = 0
            }

            if let currentBuffer = currentBuffer {
                let remainingSamples = currentBuffer.count / 2 - cursor
                let samplesToWrite = min(remainingSamples, outputBuffer.count - outputIndex)

                guard let int16ChannelData = currentBuffer.withUnsafeBytes({ $0.bindMemory(to: Int16.self).baseAddress }) else {
                    print("Failed to access Int16 channel data.")
                    break
                }

                for sampleIndex in 0 ..< samplesToWrite {
                    let sample = int16ChannelData[cursor + sampleIndex]
                    outputBuffer[outputIndex] = Float(sample) / 32768.0
                    outputIndex += 1
                }

                cursor += samplesToWrite

                if cursor >= currentBuffer.count / 2 {
                    self.currentBuffer = nil
                }
            }
        }

        outputs[outputChannel] = outputBuffer

        if finished != isFinished {
            finished = isFinished
            onProcess?(isFinished)
        }
    }

    func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "buffer":
            if let buffer = message["buffer"] as? Data {
                wasInterrupted = false
                buffers.append(buffer)
            }
        case "interrupt":
            wasInterrupted = true
        case "clearInterrupted":
            if wasInterrupted {
                wasInterrupted = false
                buffers.removeAll()
                currentBuffer = nil
            }
        default:
            break
        }
    }
}
