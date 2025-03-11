import AVFoundation
import Combine
import Foundation
import os.log

/// Main class for ElevenLabsSwift package
public class ElevenLabsSDK {
    public static let version = "1.0.1"

    private enum Constants {
        static let defaultApiOrigin = "wss://api.elevenlabs.io"
        static let defaultApiPathname = "/v1/convai/conversation?agent_id="
        static let inputSampleRate: Double = 16000
        static let sampleRate: Double = 16000
        static let ioBufferDuration: Double = 0.005
        static let volumeUpdateInterval: TimeInterval = 0.1
        static let fadeOutDuration: TimeInterval = 2.0
        static let bufferSize: AVAudioFrameCount = 1024
    }

    // MARK: - Session Config Utilities

    public enum Language: String, Codable, Sendable {
        case en, ja, zh, de, hi, fr, ko, pt, it, es, id, nl, tr, pl, sv, bg, ro, ar, cs, el, fi, ms, da, ta, uk, ru, hu, no, vi
    }

    public struct AgentPrompt: Codable, Sendable {
        public var prompt: String?

        public init(prompt: String? = nil) {
            self.prompt = prompt
        }
    }

    public struct TTSConfig: Codable, Sendable {
        public var voiceId: String?

        private enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
        }

        public init(voiceId: String? = nil) {
            self.voiceId = voiceId
        }
    }

    public struct ConversationConfigOverride: Codable, Sendable {
        public var agent: AgentConfig?
        public var tts: TTSConfig?

        public init(agent: AgentConfig? = nil, tts: TTSConfig? = nil) {
            self.agent = agent
            self.tts = tts
        }
    }

    public struct AgentConfig: Codable, Sendable {
        public var prompt: AgentPrompt?
        public var firstMessage: String?
        public var language: Language?

        private enum CodingKeys: String, CodingKey {
            case prompt
            case firstMessage = "first_message"
            case language
        }

        public init(prompt: AgentPrompt? = nil, firstMessage: String? = nil, language: Language? = nil) {
            self.prompt = prompt
            self.firstMessage = firstMessage
            self.language = language
        }
    }

    public enum LlmExtraBodyValue: Codable, Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case null
        case array([LlmExtraBodyValue])
        case dictionary([String: LlmExtraBodyValue])

        var jsonValue: Any {
            switch self {
            case let .string(str): return str
            case let .number(num): return num
            case let .boolean(bool): return bool
            case .null: return NSNull()
            case let .array(arr): return arr.map { $0.jsonValue }
            case let .dictionary(dict): return dict.mapValues { $0.jsonValue }
            }
        }
    }

    // MARK: - Audio Utilities

    public static func arrayBufferToBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func base64ToArrayBuffer(_ base64: String) -> Data? {
        Data(base64Encoded: base64)
    }

    // MARK: - Client Tools

    public typealias ClientToolHandler = @Sendable (Parameters) async throws -> String?

    public typealias Parameters = [String: Any]

    public struct ClientTools: Sendable {
        private var tools: [String: ClientToolHandler] = [:]
        private let lock = NSLock() // Ensure thread safety

        public init() {}

        public mutating func register(_ name: String, handler: @escaping @Sendable ClientToolHandler) {
            lock.withLock {
                tools[name] = handler
            }
        }

        public func handle(_ name: String, parameters: Parameters) async throws -> String? {
            let handler: ClientToolHandler? = lock.withLock { tools[name] }
            guard let handler = handler else {
                throw ClientToolError.handlerNotFound(name)
            }
            return try await handler(parameters)
        }
    }

    public enum ClientToolError: Error {
        case handlerNotFound(String)
        case invalidParameters
        case executionFailed(String)
    }

    // MARK: - Audio Processing

    public class AudioConcatProcessor {
        private var buffers: [Data] = []
        private var cursor: Int = 0
        private var currentBuffer: Data?
        private var wasInterrupted: Bool = false
        private var finished: Bool = false
        public var onProcess: ((Bool) -> Void)?

        public func process(outputs: inout [[Float]]) {
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

        public func handleMessage(_ message: [String: Any]) {
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

    // MARK: - Connection

    public enum DynamicVariableValue: Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case int(Int)

        var jsonValue: Any {
            switch self {
            case let .string(str): return str
            case let .number(num): return num
            case let .boolean(bool): return bool
            case let .int(int): return int
            }
        }
    }

    public struct SessionConfig: Sendable {
        public let signedUrl: String?
        public let agentId: String?
        public let overrides: ConversationConfigOverride?
        public let customLlmExtraBody: [String: LlmExtraBodyValue]?
        public let dynamicVariables: [String: DynamicVariableValue]?

        public init(signedUrl: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.signedUrl = signedUrl
            agentId = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(agentId: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.agentId = agentId
            signedUrl = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }
    }

    public class Connection: @unchecked Sendable {
        public let socket: URLSessionWebSocketTask
        public let conversationId: String
        public let sampleRate: Int

        private init(socket: URLSessionWebSocketTask, conversationId: String, sampleRate: Int) {
            self.socket = socket
            self.conversationId = conversationId
            self.sampleRate = sampleRate
        }

        public static func create(config: SessionConfig) async throws -> Connection {
            let origin = ProcessInfo.processInfo.environment["ELEVENLABS_CONVAI_SERVER_ORIGIN"] ?? Constants.defaultApiOrigin
            let pathname = ProcessInfo.processInfo.environment["ELEVENLABS_CONVAI_SERVER_PATHNAME"] ?? Constants.defaultApiPathname

            let urlString: String
            if let signedUrl = config.signedUrl {
                urlString = signedUrl
            } else if let agentId = config.agentId {
                urlString = "\(origin)\(pathname)\(agentId)"
            } else {
                throw ElevenLabsError.invalidConfiguration
            }

            guard let url = URL(string: urlString) else {
                throw ElevenLabsError.invalidURL
            }

            let session = URLSession(configuration: .default)
            let socket = session.webSocketTask(with: url)
            socket.resume()

            // Always send initialization event
            var initEvent: [String: Any] = ["type": "conversation_initiation_client_data"]

            // Add overrides if present
            if let overrides = config.overrides,
               let overridesDict = overrides.dictionary
            {
                initEvent["conversation_config_override"] = overridesDict
            }

            // Add custom body if present
            if let customBody = config.customLlmExtraBody {
                initEvent["custom_llm_extra_body"] = customBody.mapValues { $0.jsonValue }
            }

            // Add dynamic variables if present - Convert to JSON-compatible values
            if let dynamicVars = config.dynamicVariables {
                initEvent["dynamic_variables"] = dynamicVars.mapValues { $0.jsonValue }
            }

            let jsonData = try JSONSerialization.data(withJSONObject: initEvent)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            try await socket.send(.string(jsonString))

            let configData = try await receiveInitialMessage(socket: socket)
            return Connection(socket: socket, conversationId: configData.conversationId, sampleRate: configData.sampleRate)
        }

        private static func receiveInitialMessage(
            socket: URLSessionWebSocketTask
        ) async throws -> (conversationId: String, sampleRate: Int) {
            return try await withCheckedThrowingContinuation { continuation in
                socket.receive { result in
                    switch result {
                    case let .success(message):
                        switch message {
                        case let .string(text):
                            guard let data = text.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                                  let type = json["type"] as? String,
                                  type == "conversation_initiation_metadata",
                                  let metadata = json["conversation_initiation_metadata_event"] as? [String: Any],
                                  let conversationId = metadata["conversation_id"] as? String,
                                  let audioFormat = metadata["agent_output_audio_format"] as? String
                            else {
                                continuation.resume(throwing: ElevenLabsError.invalidInitialMessageFormat)
                                return
                            }

                            let sampleRate = Int(audioFormat.replacingOccurrences(of: "pcm_", with: "")) ?? 16000
                            continuation.resume(returning: (conversationId: conversationId, sampleRate: sampleRate))

                        case .data:
                            continuation.resume(throwing: ElevenLabsError.unexpectedBinaryMessage)

                        @unknown default:
                            continuation.resume(throwing: ElevenLabsError.unknownMessageType)
                        }
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        public func close() {
            // Use a more graceful close code
            socket.cancel(with: .normalClosure, reason: "Session ended normally".data(using: .utf8))
        }
    }

    // MARK: - Audio Input

    public class Input {
        public let audioUnit: AudioUnit
        public var audioFormat: AudioStreamBasicDescription
        public var isRecording: Bool = false
        private var recordCallback: ((AVAudioPCMBuffer, Float) -> Void)?
        private var currentAudioLevel: Float = 0.0

        private init(audioUnit: AudioUnit, audioFormat: AudioStreamBasicDescription) {
            self.audioUnit = audioUnit
            self.audioFormat = audioFormat
        }

        public static func create(sampleRate: Double) async throws -> Input {
            // 1) Initialize Audio Session (iOS only)
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setPreferredSampleRate(sampleRate)
            try audioSession.setActive(true)
            #elseif os(macOS)
            // ------------------------------------------------------------
            // macOS: No AVAudioSession. Just skip session configuration
            // ------------------------------------------------------------
            #endif

            // 2) Describe our VoiceProcessingIO Audio Unit
            var audioComponentDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_VoiceProcessingIO, // echo cancellation
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

            // 3) Create the Input instance
            let input = Input(audioUnit: audioUnit, audioFormat: AudioStreamBasicDescription())

            // 4) Enable IO for input (bus 1)
            var enableInput: UInt32 = 1
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 1,
                                 &enableInput,
                                 UInt32(MemoryLayout.size(ofValue: enableInput)))

            // 5) On macOS: Enable output (bus 0); On iOS: optionally disable it
            #if os(macOS)
            var enableOutput: UInt32 = 1
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output,
                                 0,
                                 &enableOutput,
                                 UInt32(MemoryLayout.size(ofValue: enableOutput)))
            #else
            var disableOutput: UInt32 = 0
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output,
                                 0,
                                 &disableOutput,
                                 UInt32(MemoryLayout.size(ofValue: disableOutput)))
            #endif

            // 6) Define common AudioStreamBasicDescription (16 kHz, 16-bit, mono)
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

            // 7) Set the format on bus 1 (Output scope) for capturing
            AudioUnitSetProperty(audioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 1, // bus 1
                                 &audioFormat,
                                 UInt32(MemoryLayout.size(ofValue: audioFormat)))

            // 8) On macOS, also set matching format on bus 0 (Input scope)
            #if os(macOS)
            AudioUnitSetProperty(audioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 0, // bus 0
                                 &audioFormat,
                                 UInt32(MemoryLayout.size(ofValue: audioFormat)))
            #endif

            // Keep track of the chosen format
            input.audioFormat = audioFormat

            // 9) Set the input callback
            var inputCallbackStruct = AURenderCallbackStruct(
                inputProc: inputRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(input).toOpaque())
            )
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global,
                                 1, // bus 1
                                 &inputCallbackStruct,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size))

            // 10) Initialize + Start
            AudioUnitInitialize(audioUnit)
            AudioOutputUnitStart(audioUnit)

            return input
        }


        public func setRecordCallback(_ callback: @escaping (AVAudioPCMBuffer, Float) -> Void) {
            recordCallback = callback
        }

        public func close() {
            // Use a safer approach to stop and dispose audio components
            // First stop the audio unit
            let stopStatus = AudioOutputUnitStop(audioUnit)
            if stopStatus != noErr {
                print("Warning: Failed to stop audio unit: \(stopStatus)")
            }
            
            // Then uninitialize it
            let uninitStatus = AudioUnitUninitialize(audioUnit)
            if uninitStatus != noErr {
                print("Warning: Failed to uninitialize audio unit: \(uninitStatus)")
            }
            
            // Finally dispose of it
            let disposeStatus = AudioComponentInstanceDispose(audioUnit)
            if disposeStatus != noErr {
                print("Warning: Failed to dispose audio component: \(disposeStatus)")
            }
            
            // Clear the record callback to prevent any further processing
            recordCallback = nil
        }

        private static let inputRenderCallback: AURenderCallback = {
            inRefCon,
                ioActionFlags,
                inTimeStamp,
                inBusNumber,
                inNumberFrames,
                _
                -> OSStatus in
            print("[inputRenderCallback] Called with \(inNumberFrames) frames on bus \(inBusNumber)")

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

    // MARK: - Output

    public class Output {
        public let engine: AVAudioEngine
        public let playerNode: AVAudioPlayerNode
        public let mixer: AVAudioMixerNode
        let audioQueue: DispatchQueue

        private init(engine: AVAudioEngine, playerNode: AVAudioPlayerNode, mixer: AVAudioMixerNode) {
            self.engine = engine
            self.playerNode = playerNode
            self.mixer = mixer
            audioQueue = DispatchQueue(label: "com.elevenlabs.audioQueue", qos: .userInteractive)
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

            return Output(engine: engine, playerNode: playerNode, mixer: mixer)
        }

        public func close() {
            // Stop the player node first
            if playerNode.isPlaying {
                playerNode.stop()
            }
            
            // Then stop the engine
            if engine.isRunning {
                engine.stop()
            }
            
            // Reset the engine
            engine.reset()
            
            // Detach nodes
            engine.detach(playerNode)
            engine.detach(mixer)
        }
    }

    // MARK: - Conversation

    public enum Role: String {
        case user
        case ai
    }

    public enum Mode: String {
        case speaking
        case listening
    }

    public enum Status: String {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }

    public struct Callbacks: Sendable {
        public var onConnect: @Sendable (String) -> Void = { _ in }
        public var onDisconnect: @Sendable () -> Void = {}
        public var onMessage: @Sendable (String, Role) -> Void = { _, _ in }
        public var onError: @Sendable (String, Any?) -> Void = { _, _ in }
        public var onStatusChange: @Sendable (Status) -> Void = { _ in }
        public var onModeChange: @Sendable (Mode) -> Void = { _ in }
        public var onVolumeUpdate: @Sendable (Float) -> Void = { _ in }

        public init(
               onConnect: @escaping @Sendable (String) -> Void = { _ in },
               onDisconnect: @escaping @Sendable () -> Void = {},
               onMessage: @escaping @Sendable (String, Role) -> Void = { _,_ in },
               onError: @escaping @Sendable (String, Any?) -> Void = { _,_ in },
               onStatusChange: @escaping @Sendable (Status) -> Void = { _ in },
               onModeChange: @escaping @Sendable (Mode) -> Void = { _ in },
               onVolumeUpdate: @escaping @Sendable (Float) -> Void = { _ in }
           ) {
               self.onConnect = onConnect
               self.onDisconnect = onDisconnect
               self.onMessage = onMessage
               self.onError = onError
               self.onStatusChange = onStatusChange
               self.onModeChange = onModeChange
               self.onVolumeUpdate = onVolumeUpdate
           }
    }

    public class Conversation: @unchecked Sendable {
        private let connection: Connection
        private let input: Input
        private let output: Output
        private let callbacks: Callbacks
        private let clientTools: ClientTools?

        private let modeLock = NSLock()
        private let statusLock = NSLock()
        private let volumeLock = NSLock()
        private let lastInterruptTimestampLock = NSLock()
        private let isProcessingInputLock = NSLock()

        private var inputVolumeUpdateTimer: Timer?
        private let inputVolumeUpdateInterval: TimeInterval = 0.1 // Update every 100ms
        private var currentInputVolume: Float = 0.0

        private var _mode: Mode = .listening
        private var _status: Status = .connecting
        private var _volume: Float = 1.0
        private var _lastInterruptTimestamp: Int = 0
        private var _isProcessingInput: Bool = true

        private var mode: Mode {
            get { modeLock.withLock { _mode } }
            set { modeLock.withLock { _mode = newValue } }
        }

        private var status: Status {
            get { statusLock.withLock { _status } }
            set { statusLock.withLock { _status = newValue } }
        }

        private var volume: Float {
            get { volumeLock.withLock { _volume } }
            set { volumeLock.withLock { _volume = newValue } }
        }

        private var lastInterruptTimestamp: Int {
            get { lastInterruptTimestampLock.withLock { _lastInterruptTimestamp } }
            set { lastInterruptTimestampLock.withLock { _lastInterruptTimestamp = newValue } }
        }

        private var isProcessingInput: Bool {
            get { isProcessingInputLock.withLock { _isProcessingInput } }
            set { isProcessingInputLock.withLock { _isProcessingInput = newValue } }
        }

        private var audioBuffers: [AVAudioPCMBuffer] = []
        private let audioBufferLock = NSLock()

        private var previousSamples: [Int16] = Array(repeating: 0, count: 10)
        private var isFirstBuffer = true

        private let audioConcatProcessor = ElevenLabsSDK.AudioConcatProcessor()
        private var outputBuffers: [[Float]] = [[]]

        private let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "Conversation")

        private func setupInputVolumeMonitoring() {
            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.inputVolumeUpdateInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.callbacks.onVolumeUpdate(self.currentInputVolume)
                }
            }
        }

        private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData else {
                return
            }

            var sumOfSquares: Float = 0
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength) // Convert to Int

            for channel in 0 ..< channelCount {
                let data = channelData[channel]
                for i in 0 ..< frameLength {
                    sumOfSquares += data[i] * data[i]
                }
            }

            let rms = sqrt(sumOfSquares / Float(frameLength * channelCount))
            let meterLevel = rms > 0 ? 20 * log10(rms) : -50.0 // Safeguarded

            // Normalize the meter level to a 0-1 range
            let normalizedLevel = max(0, min(1, (meterLevel + 50) / 50))

            // Call the callback with the volume level
            DispatchQueue.main.async {
                self.callbacks.onVolumeUpdate(normalizedLevel)
            }
        }

        private init(connection: Connection, input: Input, output: Output, callbacks: Callbacks, clientTools: ClientTools?) {
            self.connection = connection
            self.input = input
            self.output = output
            self.callbacks = callbacks
            self.clientTools = clientTools

            // Set the onProcess callback
            audioConcatProcessor.onProcess = { [weak self] finished in
                guard let self = self else { return }
                if finished {
                    self.updateMode(.listening)
                }
            }

            setupWebSocket()
            setupAudioProcessing()
            setupInputVolumeMonitoring()
        }

        /// Starts a new conversation session
        /// - Parameters:
        ///   - config: Session configuration
        ///   - callbacks: Callbacks for conversation events
        ///   - clientTools: Client tools callbacks (optional)
        /// - Returns: A started `Conversation` instance
        public static func startSession(config: SessionConfig, callbacks: Callbacks = Callbacks(), clientTools: ClientTools? = nil) async throws -> Conversation {
            // Step 1: Configure the audio session
            try ElevenLabsSDK.configureAudioSession()

            // Step 2: Create the WebSocket connection
            let connection = try await Connection.create(config: config)

            // Step 3: Create the audio input
            let input = try await Input.create(sampleRate: Constants.inputSampleRate)

            // Step 4: Create the audio output
            let output = try await Output.create(sampleRate: Double(connection.sampleRate))

            // Step 5: Initialize the Conversation
            let conversation = Conversation(connection: connection, input: input, output: output, callbacks: callbacks, clientTools: clientTools)

            // Step 6: Start the AVAudioEngine
            try output.engine.start()

            // Step 7: Start the player node
            output.playerNode.play()

            // Step 8: Start recording
            conversation.startRecording()

            return conversation
        }

        private func setupWebSocket() {
            callbacks.onConnect(connection.conversationId)
            updateStatus(.connected)
            receiveMessages()
        }

        private func receiveMessages() {
            // Don't attempt to receive messages if we're not connected
            guard status == .connected else { return }
            
            connection.socket.receive { [weak self] result in
                guard let self = self else { return }
                
                // Don't process messages if we're disconnecting or disconnected
                guard self.status == .connected else { return }

                switch result {
                case let .success(message):
                    self.handleWebSocketMessage(message)
                    
                    // Continue receiving messages if still connected
                    if self.status == .connected {
                        self.receiveMessages()
                    }
                    
                case let .failure(error):
                    self.logger.error("WebSocket error: \(error.localizedDescription)")
                    
                    // Check if this is a connection error
                    if (error as NSError).domain == NSPOSIXErrorDomain && 
                       ((error as NSError).code == 57 || // Socket is not connected
                        (error as NSError).code == 54 || // Connection reset by peer
                        (error as NSError).code == 60 || // Operation timed out
                        (error as NSError).code == 61) { // Connection refused
                        
                        // Handle connection errors by ending the session
                        DispatchQueue.main.async {
                            self.callbacks.onError("WebSocket connection error", error)
                            
                            // Only call endSession if we're still connected
                            if self.status == .connected {
                                self.endSession()
                            }
                        }
                    } else {
                        // For other errors, report them but try to continue
                        DispatchQueue.main.async {
                            self.callbacks.onError("WebSocket error", error)
                        }
                        
                        // Try to continue receiving messages after a short delay
                        if self.status == .connected {
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                                if self.status == .connected {
                                    self.receiveMessages()
                                }
                            }
                        }
                    }
                }
            }
        }

        private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
            switch message {
            case let .string(text):

                guard let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let type = json["type"] as? String
                else {
                    callbacks.onError("Invalid message format", nil)
                    return
                }

                switch type {
                case "client_tool_call":
                    handleClientToolCall(json)

                case "interruption":
                    handleInterruptionEvent(json)

                case "agent_response":
                    handleAgentResponseEvent(json)

                case "user_transcript":
                    handleUserTranscriptEvent(json)

                case "audio":
                    handleAudioEvent(json)

                case "ping":
                    handlePingEvent(json)

                case "internal_tentative_agent_response":
                    break

                case "internal_vad_score":
                    break

                case "internal_turn_probability":
                    break

                default:
                    callbacks.onError("Unknown message type", json)
                }

            case .data:
                callbacks.onError("Received unexpected binary message", nil)

            @unknown default:
                callbacks.onError("Received unknown message type", nil)
            }
        }

        private func handleClientToolCall(_ json: [String: Any]) {
            guard let toolCall = json["client_tool_call"] as? [String: Any],
                  let toolName = toolCall["tool_name"] as? String,
                  let toolCallId = toolCall["tool_call_id"] as? String,
                  let parameters = toolCall["parameters"] as? [String: Any]
            else {
                callbacks.onError("Invalid client tool call format", json)
                return
            }

            // Serialize parameters to JSON Data for thread-safety
            let serializedParameters: Data
            do {
                serializedParameters = try JSONSerialization.data(withJSONObject: parameters, options: [])
            } catch {
                callbacks.onError("Failed to serialize parameters", error)
                return
            }

            // Execute in a Task (now safe because of serializedParameters)
            Task { [toolName, toolCallId, serializedParameters] in
                do {
                    // Deserialize within the Task to pass into clientTools.handle
                    let deserializedParameters = try JSONSerialization.jsonObject(with: serializedParameters) as? [String: Any] ?? [:]

                    let result = try await clientTools?.handle(toolName, parameters: deserializedParameters)

                    let response: [String: Any] = [
                        "type": "client_tool_result",
                        "tool_call_id": toolCallId,
                        "result": result ?? "",
                        "is_error": false,
                    ]
                    sendWebSocketMessage(response)
                } catch {
                    let response: [String: Any] = [
                        "type": "client_tool_result",
                        "tool_call_id": toolCallId,
                        "result": error.localizedDescription,
                        "is_error": true,
                    ]
                    sendWebSocketMessage(response)
                }
            }
        }

        private func handleInterruptionEvent(_ json: [String: Any]) {
            guard let event = json["interruption_event"] as? [String: Any],
                  let eventId = event["event_id"] as? Int else { return }

            lastInterruptTimestamp = eventId
            fadeOutAudio()

            // Clear the audio buffers and stop playback
            clearAudioBuffers()
            stopPlayback()
        }

        private func handleAgentResponseEvent(_ json: [String: Any]) {
            guard let event = json["agent_response_event"] as? [String: Any],
                  let response = event["agent_response"] as? String else { return }
            callbacks.onMessage(response, .ai)
        }

        private func handleUserTranscriptEvent(_ json: [String: Any]) {
            guard let event = json["user_transcription_event"] as? [String: Any],
                  let transcript = event["user_transcript"] as? String else { return }
            callbacks.onMessage(transcript, .user)
        }

        private func handleAudioEvent(_ json: [String: Any]) {
            guard let event = json["audio_event"] as? [String: Any],
                  let audioBase64 = event["audio_base_64"] as? String,
                  let eventId = event["event_id"] as? Int,
                  lastInterruptTimestamp <= eventId else { return }

            addAudioBase64Chunk(audioBase64)
            updateMode(.speaking)
        }

        private func handlePingEvent(_ json: [String: Any]) {
            guard let event = json["ping_event"] as? [String: Any],
                  let eventId = event["event_id"] as? Int else { return }
            let response: [String: Any] = ["type": "pong", "event_id": eventId]
            sendWebSocketMessage(response)
        }

        private func sendWebSocketMessage(_ message: [String: Any]) {
            // Check if the connection is still active before sending
            guard status == .connected else {
              
                return
            }
            
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let string = String(data: data, encoding: .utf8)
            else {
                callbacks.onError("Failed to encode message", message)
                return
            }

            // Use a dispatch queue to avoid blocking
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                // Check again if we're still connected before sending
                guard self.status == .connected else { return }
                
                self.connection.socket.send(.string(string)) { [weak self] error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        self.logger.error("Failed to send WebSocket message: \(error.localizedDescription)")
                        
                        // Check if this is a connection error
                        if (error as NSError).domain == NSPOSIXErrorDomain && 
                           (error as NSError).code == 57 { // Socket is not connected
                            
                            // Only call endSession if we're still in connected state
                            if self.status == .connected {
                                self.logger.error("WebSocket connection lost, ending session")
                                
                                // Use the main queue for UI-related callbacks
                                DispatchQueue.main.async {
                                    self.callbacks.onError("WebSocket connection lost", error)
                                    self.endSession()
                                }
                            }
                        } else {
                            // For other errors, just report them
                            DispatchQueue.main.async {
                                self.callbacks.onError("Failed to send WebSocket message", error)
                            }
                        }
                    }
                }
            }
        }

        private func setupAudioProcessing() {
            // Maximum size for each audio chunk in bytes before base64 encoding
            // Since server can handle 16MB and base64 encoding increases size by ~33%,
            // we'll use 256 KB as our raw chunk size to stay safely under the limit
            let maxRawChunkSize = 256 * 1024 // 256 KB

            input.setRecordCallback { [weak self] buffer, rms in
                guard let self = self, 
                      self.isProcessingInput, 
                      self.status == .connected else { return }

                // Convert buffer data to base64 string
                if let int16ChannelData = buffer.int16ChannelData {
                    let frameLength = Int(buffer.frameLength)
                    let totalSize = frameLength * MemoryLayout<Int16>.size
                    print("Sending chunk of size \(totalSize) bytes at rate \(Constants.inputSampleRate) Hz")

                    // In most cases, the buffer will be small enough to send in one chunk
                    if totalSize <= maxRawChunkSize {
                        // Send the entire buffer at once
                        let data = Data(bytes: int16ChannelData[0], count: totalSize)
                        let base64String = data.base64EncodedString()
                        let message: [String: Any] = ["type": "user_audio_chunk", "user_audio_chunk": base64String]
                        self.sendWebSocketMessage(message)
                    } else {
                        // Split into smaller chunks if needed
                        var offset = 0
                        while offset < totalSize {
                            // Check connection status before each chunk
                            guard self.status == .connected else { break }
                            
                            let chunkSize = min(maxRawChunkSize, totalSize - offset)
                            let chunkData = Data(bytes: int16ChannelData[0].advanced(by: offset / 2), count: chunkSize)
                            let base64String = chunkData.base64EncodedString()

                            let message: [String: Any] = ["type": "user_audio_chunk", "user_audio_chunk": base64String]
                            self.sendWebSocketMessage(message)

                            offset += chunkSize
                        }
                    }
                } else {
                    self.logger.error("Failed to get int16 channel data")
                }

                // Update volume level
                self.currentInputVolume = rms

                // Optionally, call a method to update UI or notify volume changes
                DispatchQueue.main.async {
                    self.callbacks.onVolumeUpdate(rms)
                }
            }
        }

        private func updateVolume(_ buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData else { return }

            var sum: Float = 0
            let channelCount = Int(buffer.format.channelCount)

            for channel in 0 ..< channelCount {
                let data = channelData[channel]
                for i in 0 ..< Int(buffer.frameLength) {
                    sum += abs(data[i])
                }
            }

            let average = sum / Float(buffer.frameLength * buffer.format.channelCount)
            let meterLevel = 20 * log10(average)

            // Normalize the meter level to a 0-1 range
            currentInputVolume = max(0, min(1, (meterLevel + 50) / 50))
        }

        private func addAudioBase64Chunk(_ chunk: String) {
            guard let data = ElevenLabsSDK.base64ToArrayBuffer(chunk) else {
                callbacks.onError("Failed to decode audio chunk", nil)
                return
            }

            let sampleRate = Double(connection.sampleRate)
            guard let audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                callbacks.onError("Failed to create AVAudioFormat", nil)
                return
            }

            let frameCount = data.count / MemoryLayout<Int16>.size
            guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                callbacks.onError("Failed to create AVAudioPCMBuffer", nil)
                return
            }

            audioBuffer.frameLength = AVAudioFrameCount(frameCount)

            data.withUnsafeBytes { (int16Buffer: UnsafeRawBufferPointer) in
                let int16Pointer = int16Buffer.bindMemory(to: Int16.self).baseAddress!
                if let floatChannelData = audioBuffer.floatChannelData {
                    for i in 0 ..< frameCount {
                        floatChannelData[0][i] = Float(Int16(littleEndian: int16Pointer[i])) / Float(Int16.max)
                    }
                }
            }

            audioBufferLock.withLock {
                audioBuffers.append(audioBuffer)
            }

            scheduleNextBuffer()
        }

        private func scheduleNextBuffer() {
            output.audioQueue.async { [weak self] in
                guard let self = self else { return }

                let buffer: AVAudioPCMBuffer? = self.audioBufferLock.withLock {
                    self.audioBuffers.isEmpty ? nil : self.audioBuffers.removeFirst()
                }

                guard let audioBuffer = buffer else { return }

                self.output.playerNode.scheduleBuffer(audioBuffer) {
                    self.scheduleNextBuffer()
                }
                if !self.output.playerNode.isPlaying {
                    self.output.playerNode.play()
                }
            }
        }

        private func fadeOutAudio() {
            // Mute agent
            updateMode(.listening)

            // Fade out the volume
            let fadeOutDuration: TimeInterval = 2.0
            output.mixer.volume = volume
            output.mixer.volume = 0.0001

            // Reset volume back after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) { [weak self] in
                guard let self = self else { return }
                self.output.mixer.volume = self.volume
                self.clearAudioBuffers()
            }
        }

        private func updateMode(_ newMode: Mode) {
            guard mode != newMode else { return }
            mode = newMode
            callbacks.onModeChange(newMode)
        }

        private func updateStatus(_ newStatus: Status) {
            guard status != newStatus else { return }
            status = newStatus
            callbacks.onStatusChange(newStatus)
        }

        /// Ends the current conversation session
        public func endSession() {
            // Use a lock to ensure thread safety during shutdown
            statusLock.withLock {
                // Only proceed if we're not already disconnecting or disconnected
                guard _status == .connected else { return }
                
                // Update status first to prevent new operations
                _status = .disconnecting
                
                // Notify status change on main thread
                DispatchQueue.main.async {
                    self.callbacks.onStatusChange(.disconnecting)
                }
            }
            
            // Stop processing input immediately
            isProcessingInput = false
            
            // Clear audio buffers and stop playback on audio queue
            output.audioQueue.async { [weak self] in
                guard let self = self else { return }
                
                // Stop playback first
                self.output.playerNode.stop()
                
                // Then clear buffers
                self.audioBufferLock.withLock {
                    self.audioBuffers.removeAll()
                }
                
                self.audioConcatProcessor.handleMessage(["type": "clearInterrupted"])
                
                // Close connections on main thread to avoid blocking audio thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    // Close WebSocket connection
                    self.connection.close()
                    
                    // Stop and close audio components with a slight delay
                    // to allow any pending audio operations to complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        
                        // Close audio input and output
                        self.input.close()
                        self.output.close()
                        
                        // Clean up timers
                        self.inputVolumeUpdateTimer?.invalidate()
                        self.inputVolumeUpdateTimer = nil
                        
                        // Finally update status to disconnected
                        self.statusLock.withLock {
                            self._status = .disconnected
                        }
                        
                        // Notify status change
                        self.callbacks.onStatusChange(.disconnected)
                        self.callbacks.onDisconnect()
                    }
                }
            }
        }

        /// Retrieves the conversation ID
        /// - Returns: Conversation identifier
        public func getId() -> String {
            connection.conversationId
        }

        /// Retrieves the input volume
        /// - Returns: Current input volume
        public func getInputVolume() -> Float {
            0
        }

        /// Retrieves the output volume
        /// - Returns: Current output volume
        public func getOutputVolume() -> Float {
            output.mixer.volume
        }

        /// Starts recording audio input
        public func startRecording() {
            isProcessingInput = true
        }

        /// Stops recording audio input
        public func stopRecording() {
            isProcessingInput = false
        }

        private func clearAudioBuffers() {
            audioBufferLock.withLock {
                audioBuffers.removeAll()
            }
            audioConcatProcessor.handleMessage(["type": "clearInterrupted"])
        }

        private func stopPlayback() {
            output.audioQueue.async { [weak self] in
                guard let self = self else { return }
                self.output.playerNode.stop()
            }
        }
    }

    // MARK: - Errors

    /// Defines errors specific to ElevenLabsSDK
    public enum ElevenLabsError: Error, LocalizedError {
        case invalidConfiguration
        case invalidURL
        case invalidInitialMessageFormat
        case unexpectedBinaryMessage
        case unknownMessageType
        case failedToCreateAudioFormat
        case failedToCreateAudioComponent
        case failedToCreateAudioComponentInstance

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "Invalid configuration provided."
            case .invalidURL:
                return "The provided URL is invalid."
            case .failedToCreateAudioFormat:
                return "Failed to create the audio format."
            case .failedToCreateAudioComponent:
                return "Failed to create audio component."
            case .failedToCreateAudioComponentInstance:
                return "Failed to create audio component instance."
            case .invalidInitialMessageFormat:
                return "The initial message format is invalid."
            case .unexpectedBinaryMessage:
                return "Received an unexpected binary message."
            case .unknownMessageType:
                return "Received an unknown message type."
            }
        }
    }

    // MARK: - Audio Session Configuration

    private static func configureAudioSession() throws {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Configure for voice chat with minimum latency
            try audioSession.setCategory(.playAndRecord,
                                         mode: .voiceChat,
                                         options: [.allowBluetooth])

            // Set preferred IO buffer duration for lower latency
            try audioSession.setPreferredIOBufferDuration(0.005) // 5ms buffer

            // Set preferred sample rate to match our target
            try audioSession.setPreferredSampleRate(16000)

            // Request input gain control if available
            if audioSession.isInputGainSettable {
                try audioSession.setInputGain(1.0)
            }

            // Activate the session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to configure audio session: \(error.localizedDescription)")
            throw error
        }
        #elseif os(macOS)
        // ------------------------------------------------
        // macOS: No AVAudioSession. Skip entirely.
        // ------------------------------------------------
        #endif
    }
}

extension NSLock {
    /// Executes a closure within a locked context
    /// - Parameter body: Closure to execute
    /// - Returns: Result of the closure
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    /// Initializes `Data` from an array of Int16
    /// - Parameter buffer: Array of Int16 values
    init(buffer: [Int16]) {
        self = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)) as? [String: Any]
    }
}
