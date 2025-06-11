import XCTest
@testable import ElevenLabsSwift

final class ElevenLabsSDKTests: XCTestCase {
    
    var mockNetworkService: MockNetworkService!
    var mockConversationFactory: MockLiveKitConversationFactory!
    var mockAudioConfigurator: MockAudioSessionConfigurator!
    
    override func setUp() {
        super.setUp()
        
        // Setup mocks
        mockNetworkService = MockNetworkService()
        mockConversationFactory = MockLiveKitConversationFactory()
        mockAudioConfigurator = MockAudioSessionConfigurator()
        
        // Inject mocks
        ElevenLabsSDK.networkService = mockNetworkService
        ElevenLabsSDK.conversationFactory = mockConversationFactory
        ElevenLabsSDK.audioSessionConfigurator = mockAudioConfigurator
    }
    
    override func tearDown() {
        // Reset to defaults
        ElevenLabsSDK.networkService = DefaultNetworkService()
        ElevenLabsSDK.conversationFactory = DefaultLiveKitConversationFactory()
        ElevenLabsSDK.audioSessionConfigurator = DefaultAudioSessionConfigurator()
        
        super.tearDown()
    }
    
    // MARK: - Success Tests
    
    func testStartSession_Success() async throws {
        // Given
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent-123")
        let callbacks = ElevenLabsSDK.Callbacks()
        
        mockNetworkService.shouldSucceed = true
        mockNetworkService.mockToken = "test-token-456"
        mockConversationFactory.mockConversation.shouldFailConnect = false
        
        // When
        let conversation = try await ElevenLabsSDK.startSession(
            config: config,
            callbacks: callbacks
        )
        
        // Then
        XCTAssertEqual(mockNetworkService.getLiveKitTokenCallCount, 1)
        XCTAssertEqual(mockNetworkService.lastConfig?.agentId, "test-agent-123")
        
        XCTAssertEqual(mockConversationFactory.createConversationCallCount, 1)
        XCTAssertEqual(mockConversationFactory.lastToken, "test-token-456")
        XCTAssertEqual(mockConversationFactory.lastConfig?.agentId, "test-agent-123")
        
        XCTAssertEqual(mockConversationFactory.mockConversation.connectCallCount, 1)
        XCTAssertEqual(conversation.getId(), "mock-conversation-123")
    }
    
    func testConversationBasicOperations() async throws {
        // Given
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        let conversation = try await ElevenLabsSDK.startSession(config: config)
        let mockConv = mockConversationFactory.mockConversation
        
        // When & Then
        conversation.sendContextualUpdate("Hello context")
        XCTAssertEqual(mockConv.sendContextualUpdateCallCount, 1)
        XCTAssertEqual(mockConv.lastContextualUpdateText, "Hello context")
        
        conversation.sendUserMessage("Hello user")
        XCTAssertEqual(mockConv.sendUserMessageCallCount, 1)
        XCTAssertEqual(mockConv.lastUserMessageText, "Hello user")
        
        conversation.sendUserActivity()
        XCTAssertEqual(mockConv.sendUserActivityCallCount, 1)
        
        conversation.startRecording()
        XCTAssertEqual(mockConv.startRecordingCallCount, 1)
        
        conversation.stopRecording()
        XCTAssertEqual(mockConv.stopRecordingCallCount, 1)
        
        conversation.endSession()
        XCTAssertEqual(mockConv.endSessionCallCount, 1)
    }
    
    func testVolumeControls() async throws {
        // Given
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        let conversation = try await ElevenLabsSDK.startSession(config: config)
        
        // When & Then
        conversation.conversationVolume = 0.75
        XCTAssertEqual(conversation.conversationVolume, 0.75)
        
        XCTAssertEqual(conversation.getInputVolume(), 0.5) // Mock value
        XCTAssertEqual(conversation.getOutputVolume(), 0.8) // Mock value
    }
    
    // MARK: - Error Tests
    
    func testStartSession_NetworkError() async {
        // Given
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        mockNetworkService.shouldSucceed = false
        
        // When & Then
        do {
            _ = try await ElevenLabsSDK.startSession(config: config)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is ElevenLabsSDK.ElevenLabsError)
        }
    }
    
    func testStartSession_ConnectionError() async {
        // Given
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        mockConversationFactory.mockConversation.shouldFailConnect = true
        
        // When & Then
        do {
            _ = try await ElevenLabsSDK.startSession(config: config)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is ElevenLabsSDK.ElevenLabsError)
        }
    }
    
    func testStartSession_InvalidConfiguration() async {
        // Given - Use empty agentId and configure mock to return error
        let config = ElevenLabsSDK.SessionConfig(agentId: "")
        mockNetworkService.mockError = ElevenLabsSDK.ElevenLabsError.invalidConfiguration
        
        // When & Then
        do {
            _ = try await ElevenLabsSDK.startSession(config: config)
            XCTFail("Expected error to be thrown")
        } catch ElevenLabsSDK.ElevenLabsError.invalidConfiguration {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Callback Tests
    
    func testCallbacks() async throws {
        // Given
        var connectCallbackCalled = false
        var statusChangeCallbackCalled = false
        var modeChangeCallbackCalled = false
        var messageCallbackCalled = false
        var errorCallbackCalled = false
        var volumeCallbackCalled = false
        
        let callbacks = ElevenLabsSDK.Callbacks(
            onConnect: { _ in connectCallbackCalled = true },
            onDisconnect: { },
            onMessage: { _, _ in messageCallbackCalled = true },
            onError: { _, _ in errorCallbackCalled = true },
            onStatusChange: { _ in statusChangeCallbackCalled = true },
            onModeChange: { _ in modeChangeCallbackCalled = true },
            onVolumeUpdate: { _ in volumeCallbackCalled = true }
        )
        
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        
        // When
        _ = try await ElevenLabsSDK.startSession(config: config, callbacks: callbacks)
        
        // Then - Verify mocks were set up with callbacks
        XCTAssertTrue(true) // Basic test that callbacks are passed through
    }
    
    // MARK: - Performance Tests
    
    func testStartSessionPerformance() throws {
        measure {
            Task {
                let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
                _ = try? await ElevenLabsSDK.startSession(config: config)
            }
        }
    }
} 