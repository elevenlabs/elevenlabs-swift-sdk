import Accelerate
import AVFoundation

/// Taps the raw microphone input to detect speech activity while muted.
final class RawMicrophoneTap: @unchecked Sendable {
    
    typealias OnSpeechDetected = @Sendable (_ isSpeaking: Bool, _ level: Float) -> Void
    
    private let audioEngine = AVAudioEngine()
    private let onSpeechDetected: OnSpeechDetected
    private let isMutedProvider: @Sendable () -> Bool
    private let speechThreshold: Float
    private let silenceThreshold: Float
    private let silenceFramesRequired: Int
    
    // State managed on audio thread (callbacks are serialized)
    private var isSpeaking = false
    private var silenceFrameCount = 0
    private var isRunning = false
    
    init(
        speechThreshold: Float = 0.02,
        silenceThreshold: Float = 0.01,
        silenceFramesRequired: Int = 10,
        isMutedProvider: @escaping @Sendable () -> Bool,
        onSpeechDetected: @escaping OnSpeechDetected
    ) {
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.silenceFramesRequired = silenceFramesRequired
        self.isMutedProvider = isMutedProvider
        self.onSpeechDetected = onSpeechDetected
    }
    
    func start() throws {
        guard !isRunning else { return }
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
    }
    
    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isMutedProvider() else { return } // Only process when muted
        
        let level = calculateRMS(buffer)
        let wasSpeaking = isSpeaking
        
        if level > speechThreshold {
            isSpeaking = true
            silenceFrameCount = 0
        } else if level < silenceThreshold {
            silenceFrameCount += 1
            if silenceFrameCount >= silenceFramesRequired {
                isSpeaking = false
            }
        }
        
        if wasSpeaking != isSpeaking {
            onSpeechDetected(isSpeaking, level)
        }
    }
    
    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = UInt(buffer.frameLength)
        guard count > 0 else { return 0 }
        
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, count)
        return rms
    }
    
    deinit {
        stop()
    }
}
