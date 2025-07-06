//
//  Output.swift
//  ElevenLabsSDK
//
//  Created by Mathew Gacy on 7/6/25.
//

import AVFoundation
import Foundation

public class Output {
    typealias ElevenLabsError = ElevenLabsSDK.ElevenLabsError

    public let engine: AVAudioEngine
    public let playerNode: AVAudioPlayerNode
    public let mixer: AVAudioMixerNode
    let audioQueue: DispatchQueue
    let audioFormat: AVAudioFormat

    private init(engine: AVAudioEngine, playerNode: AVAudioPlayerNode, mixer: AVAudioMixerNode, audioFormat: AVAudioFormat) {
        self.engine = engine
        self.playerNode = playerNode
        self.mixer = mixer
        self.audioFormat = audioFormat
        audioQueue = DispatchQueue(label: "com.elevenlabs.audioQueue", qos: .userInteractive)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    public static func create(sampleRate: Double) async throws -> Output {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        engine.attach(playerNode)
        engine.attach(mixer)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw ElevenLabsError.failedToCreateAudioFormat
        }
        engine.connect(playerNode, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)

        return Output(engine: engine, playerNode: playerNode, mixer: mixer, audioFormat: format)
    }

    public func close() {
        engine.stop()
        // see AVAudioEngine documentation
        playerNode.stop()
        mixer.removeTap(onBus: 0)
    }

    public func startPlaying() throws {
        try engine.start()
        playerNode.play()
    }

    @objc private func handleInterruption() throws {
        engine.connect(playerNode, to: mixer, format: audioFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: audioFormat)
        try startPlaying()
    }
}
