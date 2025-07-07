@testable import ElevenLabsSwift
import Foundation

// MARK: - Mock Network Service

public final class MockNetworkService: ElevenLabsNetworkServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldSucceed = true
    private var _mockToken = "mock-livekit-token-12345"
    private var _mockError: Error?
    private var _getLiveKitTokenCallCount = 0
    private var _lastConfig: ElevenLabsSDK.SessionConfig?

    public var shouldSucceed: Bool {
        get { lock.withLock { _shouldSucceed } }
        set { lock.withLock { _shouldSucceed = newValue } }
    }

    public var mockToken: String {
        get { lock.withLock { _mockToken } }
        set { lock.withLock { _mockToken = newValue } }
    }

    public var mockError: Error? {
        get { lock.withLock { _mockError } }
        set { lock.withLock { _mockError = newValue } }
    }

    public var getLiveKitTokenCallCount: Int { lock.withLock { _getLiveKitTokenCallCount } }

    public var lastConfig: ElevenLabsSDK.SessionConfig? { lock.withLock { _lastConfig } }

    public func getLiveKitToken(config: ElevenLabsSDK.SessionConfig) async throws -> String {
        lock.withLock {
            _getLiveKitTokenCallCount += 1
            _lastConfig = config
        }

        let (error, shouldSucceed, token) = lock.withLock { (_mockError, _shouldSucceed, _mockToken) }

        if let error = error {
            throw error
        }

        if !shouldSucceed {
            throw ElevenLabsSDK.ElevenLabsError.invalidResponse
        }

        if let conversationToken = config.conversationToken {
            return conversationToken
        }

        return token
    }
}

// MARK: - Mock Conversation

public final class MockLiveKitConversation: LiveKitConversationProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _connectCallCount = 0
    private var _sendContextualUpdateCallCount = 0
    private var _sendUserMessageCallCount = 0
    private var _sendUserActivityCallCount = 0
    private var _endSessionCallCount = 0
    private var _startRecordingCallCount = 0
    private var _stopRecordingCallCount = 0
    private var _shouldFailConnect = false
    private var _mockConversationId = "mock-conversation-123"
    private var _mockInputVolume: Float = 0.5
    private var _mockOutputVolume: Float = 0.8
    private var _conversationVolume: Float = 1.0
    private var _lastContextualUpdateText: String?
    private var _lastUserMessageText: String?

    public var connectCallCount: Int { lock.withLock { _connectCallCount } }

    public var sendContextualUpdateCallCount: Int { lock.withLock { _sendContextualUpdateCallCount } }

    public var sendUserMessageCallCount: Int { lock.withLock { _sendUserMessageCallCount } }

    public var sendUserActivityCallCount: Int { lock.withLock { _sendUserActivityCallCount } }

    public var endSessionCallCount: Int { lock.withLock { _endSessionCallCount } }

    public var startRecordingCallCount: Int { lock.withLock { _startRecordingCallCount } }

    public var stopRecordingCallCount: Int { lock.withLock { _stopRecordingCallCount } }

    public var shouldFailConnect: Bool {
        get { lock.withLock { _shouldFailConnect } }
        set { lock.withLock { _shouldFailConnect = newValue } }
    }

    public var mockConversationId: String {
        get { lock.withLock { _mockConversationId } }
        set { lock.withLock { _mockConversationId = newValue } }
    }

    public var mockInputVolume: Float {
        get { lock.withLock { _mockInputVolume } }
        set { lock.withLock { _mockInputVolume = newValue } }
    }

    public var mockOutputVolume: Float {
        get { lock.withLock { _mockOutputVolume } }
        set { lock.withLock { _mockOutputVolume = newValue } }
    }

    public var conversationVolume: Float {
        get { lock.withLock { _conversationVolume } }
        set { lock.withLock { _conversationVolume = newValue } }
    }

    public var lastContextualUpdateText: String? { lock.withLock { _lastContextualUpdateText } }

    public var lastUserMessageText: String? { lock.withLock { _lastUserMessageText } }

    public func connect() async throws {
        let shouldFail = lock.withLock {
            _connectCallCount += 1
            return _shouldFailConnect
        }

        if shouldFail {
            throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession
        }
    }

    public func sendContextualUpdate(_ text: String) {
        lock.withLock {
            _sendContextualUpdateCallCount += 1
            _lastContextualUpdateText = text
        }
    }

    public func sendUserMessage(_ text: String?) {
        lock.withLock {
            _sendUserMessageCallCount += 1
            _lastUserMessageText = text
        }
    }

    public func sendUserActivity() {
        lock.withLock {
            _sendUserActivityCallCount += 1
        }
    }

    public func endSession() {
        lock.withLock {
            _endSessionCallCount += 1
        }
    }

    public func getId() -> String {
        return lock.withLock { _mockConversationId }
    }

    public func getInputVolume() -> Float {
        return lock.withLock { _mockInputVolume }
    }

    public func getOutputVolume() -> Float {
        return lock.withLock { _mockOutputVolume }
    }

    public func startRecording() {
        lock.withLock {
            _startRecordingCallCount += 1
        }
    }

    public func stopRecording() {
        lock.withLock {
            _stopRecordingCallCount += 1
        }
    }
}

// MARK: - Mock Conversation Factory

public final class MockLiveKitConversationFactory: LiveKitConversationFactoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _mockConversation = MockLiveKitConversation()
    private var _createConversationCallCount = 0
    private var _lastToken: String?
    private var _lastConfig: ElevenLabsSDK.SessionConfig?

    public var mockConversation: MockLiveKitConversation {
        get { lock.withLock { _mockConversation } }
        set { lock.withLock { _mockConversation = newValue } }
    }

    public var createConversationCallCount: Int { lock.withLock { _createConversationCallCount } }

    public var lastToken: String? { lock.withLock { _lastToken } }

    public var lastConfig: ElevenLabsSDK.SessionConfig? { lock.withLock { _lastConfig } }

    public func createConversation(
        token: String,
        config: ElevenLabsSDK.SessionConfig,
        callbacks _: ElevenLabsSDK.Callbacks,
        clientTools _: ElevenLabsSDK.ClientTools?
    ) -> LiveKitConversationProtocol {
        return lock.withLock {
            _createConversationCallCount += 1
            _lastToken = token
            _lastConfig = config
            return _mockConversation
        }
    }
}

// MARK: - Mock Audio Session Configurator

public final class MockAudioSessionConfigurator: AudioSessionConfiguratorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _configureCallCount = 0
    private var _shouldFail = false
    private var _mockError: Error?

    public var configureCallCount: Int { lock.withLock { _configureCallCount } }

    public var shouldFail: Bool {
        get { lock.withLock { _shouldFail } }
        set { lock.withLock { _shouldFail = newValue } }
    }

    public var mockError: Error? {
        get { lock.withLock { _mockError } }
        set { lock.withLock { _mockError = newValue } }
    }

    public func configureAudioSession() throws {
        let (error, shouldFail) = lock.withLock {
            _configureCallCount += 1
            return (_mockError, _shouldFail)
        }

        if let error = error {
            throw error
        }

        if shouldFail {
            throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession
        }
    }
}
