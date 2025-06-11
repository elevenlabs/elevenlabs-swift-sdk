import Foundation
@testable import ElevenLabsSwift

// MARK: - Mock Network Service
public class MockNetworkService: ElevenLabsNetworkServiceProtocol {
    public var shouldSucceed = true
    public var mockToken = "mock-livekit-token-12345"
    public var mockError: Error?
    public var getLiveKitTokenCallCount = 0
    public var lastConfig: ElevenLabsSDK.SessionConfig?
    
    public func getLiveKitToken(config: ElevenLabsSDK.SessionConfig) async throws -> String {
        getLiveKitTokenCallCount += 1
        lastConfig = config
        
        if let error = mockError {
            throw error
        }
        
        if !shouldSucceed {
            throw ElevenLabsSDK.ElevenLabsError.invalidResponse
        }
        
        return mockToken
    }
}

// MARK: - Mock Conversation
public class MockLiveKitConversation: LiveKitConversationProtocol {
    public var connectCallCount = 0
    public var sendContextualUpdateCallCount = 0
    public var sendUserMessageCallCount = 0
    public var sendUserActivityCallCount = 0
    public var endSessionCallCount = 0
    public var startRecordingCallCount = 0
    public var stopRecordingCallCount = 0
    
    public var shouldFailConnect = false
    public var mockConversationId = "mock-conversation-123"
    public var mockInputVolume: Float = 0.5
    public var mockOutputVolume: Float = 0.8
    public var conversationVolume: Float = 1.0
    
    public var lastContextualUpdateText: String?
    public var lastUserMessageText: String?
    
    public func connect() async throws {
        connectCallCount += 1
        if shouldFailConnect {
            throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession
        }
    }
    
    public func sendContextualUpdate(_ text: String) {
        sendContextualUpdateCallCount += 1
        lastContextualUpdateText = text
    }
    
    public func sendUserMessage(_ text: String?) {
        sendUserMessageCallCount += 1
        lastUserMessageText = text
    }
    
    public func sendUserActivity() {
        sendUserActivityCallCount += 1
    }
    
    public func endSession() {
        endSessionCallCount += 1
    }
    
    public func getId() -> String {
        return mockConversationId
    }
    
    public func getInputVolume() -> Float {
        return mockInputVolume
    }
    
    public func getOutputVolume() -> Float {
        return mockOutputVolume
    }
    
    public func startRecording() {
        startRecordingCallCount += 1
    }
    
    public func stopRecording() {
        stopRecordingCallCount += 1
    }
}

// MARK: - Mock Conversation Factory
public class MockLiveKitConversationFactory: LiveKitConversationFactoryProtocol {
    public var mockConversation = MockLiveKitConversation()
    public var createConversationCallCount = 0
    public var lastToken: String?
    public var lastConfig: ElevenLabsSDK.SessionConfig?
    
    public func createConversation(
        token: String,
        config: ElevenLabsSDK.SessionConfig,
        callbacks: ElevenLabsSDK.Callbacks,
        clientTools: ElevenLabsSDK.ClientTools?
    ) -> LiveKitConversationProtocol {
        createConversationCallCount += 1
        lastToken = token
        lastConfig = config
        return mockConversation
    }
}

// MARK: - Mock Audio Session Configurator
public class MockAudioSessionConfigurator: AudioSessionConfiguratorProtocol {
    public var configureCallCount = 0
    public var shouldFail = false
    public var mockError: Error?
    
    public func configureAudioSession() throws {
        configureCallCount += 1
        
        if let error = mockError {
            throw error
        }
        
        if shouldFail {
            throw ElevenLabsSDK.ElevenLabsError.failedToConfigureAudioSession
        }
    }
} 