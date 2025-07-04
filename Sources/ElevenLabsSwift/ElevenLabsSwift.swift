import AVFoundation
import Combine
import DeviceKit
import Foundation
import LiveKit
import os.log

/// Main class for ElevenLabsSwift package
@available(macOS 11.0, iOS 14.0, *)
public class ElevenLabsSDK {
    public static let version = "1.2.0"

    // MARK: - Dependencies (Injectable) - Make thread-safe

    private static let networkServiceLock = NSLock()
    private nonisolated(unsafe) static var _networkService: ElevenLabsNetworkServiceProtocol = DefaultNetworkService()
    @MainActor
    public static var networkService: ElevenLabsNetworkServiceProtocol {
        get { networkServiceLock.withLock { _networkService } }
        set { networkServiceLock.withLock { _networkService = newValue } }
    }

    private static let conversationFactoryLock = NSLock()
    private nonisolated(unsafe) static var _conversationFactory: LiveKitConversationFactoryProtocol = DefaultLiveKitConversationFactory()
    @MainActor
    public static var conversationFactory: LiveKitConversationFactoryProtocol {
        get { conversationFactoryLock.withLock { _conversationFactory } }
        set { conversationFactoryLock.withLock { _conversationFactory = newValue } }
    }

    private static let audioSessionConfiguratorLock = NSLock()
    private nonisolated(unsafe) static var _audioSessionConfigurator: AudioSessionConfiguratorProtocol = DefaultAudioSessionConfigurator()
    @MainActor
    public static var audioSessionConfigurator: AudioSessionConfiguratorProtocol {
        get { audioSessionConfiguratorLock.withLock { _audioSessionConfigurator } }
        set { audioSessionConfiguratorLock.withLock { _audioSessionConfigurator = newValue } }
    }

    enum Constants {
        static let liveKitUrl = "wss://livekit.rtc.elevenlabs.io"
        static let apiBaseUrl = "https://api.elevenlabs.io"
        static let volumeUpdateInterval: TimeInterval = 0.1
        static let inputSampleRate: Double = 48000
        static let sampleRate: Double = 48000
        static let ioBufferDuration: Double = 0.005
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

    // MARK: - Dynamic Variables

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
        public let conversationToken: String?
        public let overrides: ConversationConfigOverride?
        public let customLlmExtraBody: [String: LlmExtraBodyValue]?
        public let dynamicVariables: [String: DynamicVariableValue]?

        public init(signedUrl: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.signedUrl = signedUrl
            agentId = nil
            conversationToken = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(agentId: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.agentId = agentId
            signedUrl = nil
            conversationToken = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(conversationToken: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.conversationToken = conversationToken
            agentId = nil
            signedUrl = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
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

        /// A callback that receives the updated RMS level of the output audio
        public var onOutputVolumeUpdate: @Sendable (Float) -> Void = { _ in }

        /// A callback that informs about a message correction.
        /// - Parameters:
        ///   - original: The original message. (Type: `String`)
        ///   - corrected: The corrected message. (Type: `String`)
        ///   - role: The role associated with the correction. (Type: `Role`)
        public var onMessageCorrection: @Sendable (String, String, Role) -> Void = { _, _, _ in }

        public init() {}
    }

    // MARK: - Main Conversation API

    /// Starts a new conversation session using WebRTC/LiveKit
    /// - Parameters:
    ///   - config: Session configuration
    ///   - callbacks: Callbacks for conversation events
    ///   - clientTools: Client tools callbacks (optional)
    /// - Returns: A started `LiveKitConversationProtocol` instance
    public static func startSession(
        config: SessionConfig,
        callbacks: Callbacks = Callbacks(),
        clientTools: ClientTools? = nil
    ) async throws -> LiveKitConversationProtocol {
        // Configure audio session before starting
        try await audioSessionConfigurator.configureAudioSession()

        // Get LiveKit token from ElevenLabs backend (mockable)
        let liveKitToken = try await networkService.getLiveKitToken(config: config)

        // Create and connect to LiveKit room (mockable)
        let conversation = await conversationFactory.createConversation(
            token: liveKitToken,
            config: config,
            callbacks: callbacks,
            clientTools: clientTools
        )

        try await conversation.connect()
        return conversation
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
        case failedToConfigureAudioSession
        case invalidResponse
        case invalidTokenResponse

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
            case .failedToConfigureAudioSession:
                return "Failed to configure audio session."
            case .invalidResponse:
                return "Invalid response from server."
            case .invalidTokenResponse:
                return "Invalid token response from server."
            }
        }
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

extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)) as? [String: Any]
    }
}

// MARK: - Default Implementations

@available(macOS 11.0, iOS 14.0, *)
public final class DefaultNetworkService: @unchecked Sendable, ElevenLabsNetworkServiceProtocol {
    public init() {}

    public func getLiveKitToken(config: ElevenLabsSDK.SessionConfig) async throws -> String {
        let baseUrl = ElevenLabsSDK.Constants.apiBaseUrl

        // Handle different authentication scenarios like React implementation
        if let conversationToken = config.conversationToken {
            // Direct token provided
            return conversationToken
        } else if let agentId = config.agentId {
            // Agent ID provided - fetch token from API using query parameter
            let urlString = "\(baseUrl)/v1/convai/conversation/token?agent_id=\(agentId)"
            guard let url = URL(string: urlString) else {
                throw ElevenLabsSDK.ElevenLabsError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ElevenLabsSDK.ElevenLabsError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                let errorMessage = "ElevenLabs API returned \(httpResponse.statusCode)"
                if httpResponse.statusCode == 401 {
                    throw ElevenLabsSDK.ElevenLabsError.invalidConfiguration
                }
                throw ElevenLabsSDK.ElevenLabsError.invalidResponse
            }

            guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = jsonResponse["token"] as? String
            else {
                throw ElevenLabsSDK.ElevenLabsError.invalidTokenResponse
            }

            if token.isEmpty {
                throw ElevenLabsSDK.ElevenLabsError.invalidTokenResponse
            }

            return token
        } else {
            throw ElevenLabsSDK.ElevenLabsError.invalidConfiguration
        }
    }
}

@available(macOS 11.0, iOS 14.0, *)
public final class DefaultLiveKitConversationFactory: @unchecked Sendable, LiveKitConversationFactoryProtocol {
    public init() {}

    public func createConversation(
        token: String,
        config: ElevenLabsSDK.SessionConfig,
        callbacks: ElevenLabsSDK.Callbacks,
        clientTools: ElevenLabsSDK.ClientTools?
    ) -> LiveKitConversationProtocol {
        return LiveKitConversation(
            token: token,
            config: config,
            callbacks: callbacks,
            clientTools: clientTools
        )
    }
}

@available(macOS 11.0, iOS 14.0, *)
public final class DefaultAudioSessionConfigurator: @unchecked Sendable, AudioSessionConfiguratorProtocol {
    public init() {}

    public func configureAudioSession() throws {
        #if os(iOS) || os(tvOS)
            let audioSession = AVAudioSession.sharedInstance()
            let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "AudioSession")

            do {
                let sessionMode: AVAudioSession.Mode = .voiceChat
                logger.info("Configuring session with category: .playAndRecord, mode: .voiceChat")
                try audioSession.setCategory(.playAndRecord, mode: sessionMode, options: [.defaultToSpeaker, .allowBluetooth])

                try audioSession.setPreferredIOBufferDuration(ElevenLabsSDK.Constants.ioBufferDuration)
                try audioSession.setPreferredSampleRate(ElevenLabsSDK.Constants.inputSampleRate)

                if audioSession.isInputGainSettable {
                    try audioSession.setInputGain(1.0)
                }

                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                logger.info("Audio session configured and activated.")

            } catch {
                logger.error("Failed to configure audio session: \(error.localizedDescription)")
                throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession
            }
        #else
            // macOS doesn't use AVAudioSession, just log that configuration is skipped
            let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "AudioSession")
            logger.info("Audio session configuration skipped on macOS")
        #endif
    }
}
