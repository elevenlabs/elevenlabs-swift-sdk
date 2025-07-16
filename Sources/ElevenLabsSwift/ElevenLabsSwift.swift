import AVFoundation
import Combine
import DeviceKit
import Foundation
import LiveKit
import os.log

/// Main class for ElevenLabsSwift package
@available(macOS 11.0, iOS 14.0, *)
public class ElevenLabsSDK {
    public static let version = "2.0.0"

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
        public let agentId: String?
        public let conversationToken: String?
        public let overrides: ConversationConfigOverride?
        public let customLlmExtraBody: [String: LlmExtraBodyValue]?
        public let dynamicVariables: [String: DynamicVariableValue]?

        public init(agentId: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.agentId = agentId
            conversationToken = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(conversationToken: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.conversationToken = conversationToken
            agentId = nil
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

    /// Starts a new conversation session using WebRTC
    ///
    /// This method initializes a real-time conversation with an ElevenLabs agent.
    /// It handles audio session configuration, WebRTC connection setup, and
    /// agent communication through LiveKit infrastructure.
    ///
    /// - Parameters:
    ///   - config: Session configuration containing agent ID for public agents or a conversation token for private agents
    ///   - callbacks: Event handlers for conversation lifecycle and messages
    ///   - clientTools: Optional tools that the agent can call during conversation
    /// - Returns: A connected conversation instance conforming to `LiveKitConversationProtocol`
    /// - Throws: `ElevenLabsError` if configuration is invalid, connection fails, or audio setup fails
    ///
    /// ## Usage Example:
    /// ```swift
    /// let config = ElevenLabsSDK.SessionConfig(agentId: "your-agent-id")
    /// var callbacks = ElevenLabsSDK.Callbacks()
    /// callbacks.onConnect = { id in print("Connected: \(id)") }
    /// callbacks.onMessage = { msg, role in print("\(role): \(msg)") }
    ///
    /// let conversation = try await ElevenLabsSDK.startSession(
    ///     config: config,
    ///     callbacks: callbacks
    /// )
    /// ```
    ///
    /// ## Error Handling:
    /// - `invalidConfiguration`: Check your agent ID or conversation token
    /// - `failedToConfigureAudioSession`: Verify microphone permissions
    /// - `connectionFailed`: Check internet connection and try again
    /// - `authenticationFailed`: Verify API credentials
    ///
    /// - Note: Requires microphone permission (`NSMicrophoneUsageDescription` in Info.plist)
    /// - Warning: This method must be called from a Task or async context
    public static func startSession(
        config: SessionConfig,
        callbacks: Callbacks = Callbacks(),
        clientTools: ClientTools? = nil
    ) async throws -> LiveKitConversationProtocol {
        // Configure audio session before starting
        try await audioSessionConfigurator.configureAudioSession()

        let liveKitToken: String
        if let conversationToken = config.conversationToken {
            liveKitToken = conversationToken
        } else {
            liveKitToken = try await networkService.getLiveKitToken(config: config)
        }

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
    public enum ElevenLabsError: Error, LocalizedError, Equatable {
        case invalidConfiguration(String)
        case invalidURL(String)
        case invalidInitialMessageFormat
        case unexpectedBinaryMessage
        case unknownMessageType(String)
        case failedToCreateAudioFormat
        case failedToCreateAudioComponent
        case failedToCreateAudioComponentInstance
        case failedToConfigureAudioSession(String)
        case invalidResponse(statusCode: Int)
        case invalidTokenResponse(String)
        case connectionFailed(String)
        case authenticationFailed(String)
        case networkError(String)
        case audioSystemError(String)
        case microphonePermissionDenied
        case roomConnectionTimeout
        case agentNotAvailable

        public var errorDescription: String? {
            switch self {
            case let .invalidConfiguration(details):
                return "Invalid configuration: \(details)"
            case let .invalidURL(url):
                return "Invalid URL: \(url)"
            case .failedToCreateAudioFormat:
                return "Failed to create audio format for recording"
            case .failedToCreateAudioComponent:
                return "Failed to create audio component"
            case .failedToCreateAudioComponentInstance:
                return "Failed to create audio component instance"
            case .invalidInitialMessageFormat:
                return "Initial message format is invalid"
            case .unexpectedBinaryMessage:
                return "Received unexpected binary message"
            case let .unknownMessageType(type):
                return "Unknown message type: \(type)"
            case let .failedToConfigureAudioSession(reason):
                return "Failed to configure audio session: \(reason)"
            case let .invalidResponse(statusCode):
                return "Invalid response from server (HTTP \(statusCode))"
            case let .invalidTokenResponse(reason):
                return "Invalid token response: \(reason)"
            case let .connectionFailed(reason):
                return "Connection failed: \(reason)"
            case let .authenticationFailed(reason):
                return "Authentication failed: \(reason)"
            case let .networkError(reason):
                return "Network error: \(reason)"
            case let .audioSystemError(reason):
                return "Audio system error: \(reason)"
            case .microphonePermissionDenied:
                return "Microphone permission denied. Please enable microphone access in Settings."
            case .roomConnectionTimeout:
                return "Room connection timed out. Please check your internet connection."
            case .agentNotAvailable:
                return "Agent is not available. Please try again later."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .invalidConfiguration:
                return "Please check your agent ID or signed URL configuration."
            case .invalidURL:
                return "Please verify the URL format and try again."
            case .failedToConfigureAudioSession:
                return "Please check your audio permissions and try again."
            case let .invalidResponse(statusCode) where statusCode == 401:
                return "Please verify your API key and authentication."
            case let .invalidResponse(statusCode) where statusCode >= 500:
                return "Server error. Please try again later."
            case .connectionFailed:
                return "Please check your internet connection and try again."
            case .authenticationFailed:
                return "Please verify your API credentials."
            case .networkError:
                return "Please check your internet connection."
            case .audioSystemError:
                return "Please check your audio settings and permissions."
            case .microphonePermissionDenied:
                return "Go to Settings > Privacy & Security > Microphone to enable access."
            case .roomConnectionTimeout:
                return "Please check your internet connection and try again."
            case .agentNotAvailable:
                return "The agent may be busy. Please try again in a few moments."
            default:
                return "Please try again or contact support if the issue persists."
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
    private let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "NetworkService")

    public init() {}

    public func getLiveKitToken(config: ElevenLabsSDK.SessionConfig) async throws -> String {
        let baseUrl = ElevenLabsSDK.Constants.apiBaseUrl

        if let conversationToken = config.conversationToken {
            // Direct token provided
            return conversationToken
        } else if let agentId = config.agentId {
            // Agent ID provided - fetch token from API using query parameter
            let urlString = "\(baseUrl)/v1/convai/conversation/token?agent_id=\(agentId)"

            guard let url = URL(string: urlString) else {
                throw ElevenLabsSDK.ElevenLabsError.invalidURL(urlString)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ElevenLabsSDK.ElevenLabsError.networkError("Invalid response from server")
            }

            guard httpResponse.statusCode == 200 else {
                let errorMessage = "ElevenLabs API returned \(httpResponse.statusCode)"

                // Try to log error body
                if let errorString = String(data: data, encoding: .utf8) {
                    logger.error("Error response body: \(errorString)")
                }

                if httpResponse.statusCode == 401 {
                    throw ElevenLabsSDK.ElevenLabsError.authenticationFailed(errorMessage)
                }
                throw ElevenLabsSDK.ElevenLabsError.invalidResponse(statusCode: httpResponse.statusCode)
            }

            // Log raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                logger.debug("Raw response: \(responseString)")
            }

            guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = jsonResponse["token"] as? String
            else {
                throw ElevenLabsSDK.ElevenLabsError.invalidTokenResponse("Failed to parse token from response")
            }

            if token.isEmpty {
                throw ElevenLabsSDK.ElevenLabsError.invalidTokenResponse("Empty token received from server")
            }

            return token
        } else {
            throw ElevenLabsSDK.ElevenLabsError.invalidConfiguration("Either agentId or conversationToken must be provided")
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
                throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession(error.localizedDescription)
            }
        #else
            // macOS doesn't use AVAudioSession, just log that configuration is skipped
            let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "AudioSession")
            logger.info("Audio session configuration skipped on macOS")
        #endif
    }
}
