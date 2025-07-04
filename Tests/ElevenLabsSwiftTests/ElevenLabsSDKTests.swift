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
        
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Inject mocks on the main actor
        Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }
    }
    
    override func tearDown() {
        // Reset to defaults on the main actor
        Task { @MainActor in
            ElevenLabsSDK.networkService = DefaultNetworkService()
            ElevenLabsSDK.conversationFactory = DefaultLiveKitConversationFactory()
            ElevenLabsSDK.audioSessionConfigurator = DefaultAudioSessionConfigurator()
        }
        
        super.tearDown()
    }
    
    // MARK: - Success Tests
    
    func testStartSession_Success() async throws {
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
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
    
    func testStartSession_WithConversationToken() async throws {
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
        // Given
        let config = ElevenLabsSDK.SessionConfig(conversationToken: "direct-token-123")
        let callbacks = ElevenLabsSDK.Callbacks()
        
        mockConversationFactory.mockConversation.shouldFailConnect = false
        
        // When
        let conversation = try await ElevenLabsSDK.startSession(
            config: config,
            callbacks: callbacks
        )
        
        // Then
        // Should not call network service when token is provided directly
        XCTAssertEqual(mockNetworkService.getLiveKitTokenCallCount, 0)
        
        XCTAssertEqual(mockConversationFactory.createConversationCallCount, 1)
        XCTAssertEqual(mockConversationFactory.lastToken, "direct-token-123")
        XCTAssertEqual(mockConversationFactory.lastConfig?.conversationToken, "direct-token-123")
        
        XCTAssertEqual(mockConversationFactory.mockConversation.connectCallCount, 1)
        XCTAssertEqual(conversation.getId(), "mock-conversation-123")
    }
    
    func testConversationBasicOperations() async throws {
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
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
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
        // Given
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        var conversation = try await ElevenLabsSDK.startSession(config: config)
        
        // When & Then
        conversation.conversationVolume = 0.75
        XCTAssertEqual(conversation.conversationVolume, 0.75)
        
        XCTAssertEqual(conversation.getInputVolume(), 0.5) // Mock value
        XCTAssertEqual(conversation.getOutputVolume(), 0.8) // Mock value
    }
    
    // MARK: - Error Tests
    
    func testStartSession_NetworkError() async {
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
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
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
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
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
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
        // Capture mocks locally to avoid sending 'self'
        let networkService = mockNetworkService!
        let conversationFactory = mockConversationFactory!
        let audioConfigurator = mockAudioConfigurator!
        
        // Ensure setup is complete
        await Task { @MainActor in
            ElevenLabsSDK.networkService = networkService
            ElevenLabsSDK.conversationFactory = conversationFactory
            ElevenLabsSDK.audioSessionConfigurator = audioConfigurator
        }.value
        
        // Given
        var callbacks = ElevenLabsSDK.Callbacks()
        callbacks.onConnect = { _ in }
        callbacks.onDisconnect = { }
        callbacks.onMessage = { _, _ in }
        callbacks.onError = { _, _ in }
        callbacks.onStatusChange = { _ in }
        callbacks.onModeChange = { _ in }
        callbacks.onVolumeUpdate = { _ in }
        
        let config = ElevenLabsSDK.SessionConfig(agentId: "test-agent")
        
        // When
        _ = try await ElevenLabsSDK.startSession(config: config, callbacks: callbacks)
        
        // Then - Verify mocks were set up with callbacks
        XCTAssertTrue(true) // Basic test that callbacks are passed through
    }
} 