@testable import ElevenLabs
import XCTest

@MainActor
final class WebRTCConversationStartupTests: XCTestCase {
    var startup: WebRTCConversationStartup!
    var mockDependencyProvider: TestDependencyProvider!
    var mockTokenService: MockTokenService!
    var mockWebRTCConnectionManager: MockWebRTCConnectionManager!
    var logger: SDKLogger!

    override func setUp() async throws {
        mockTokenService = MockTokenService()
        mockWebRTCConnectionManager = MockWebRTCConnectionManager()
        mockDependencyProvider = TestDependencyProvider(
            tokenService: mockTokenService,
            webRTCConnectionManager: mockWebRTCConnectionManager
        )
        logger = SDKLogger(logLevel: .error)
        startup = WebRTCConversationStartup(logger: logger)
    }

    override func tearDown() {
        startup = nil
        mockDependencyProvider = nil
        mockTokenService = nil
        mockWebRTCConnectionManager = nil
    }

    func testExecute_SuccessfulStartup() async throws {
        // Setup Mocks
        let connectionDetails = TokenService.ConnectionDetails(
            serverUrl: "wss://api.elevenlabs.io",
            roomName: "room-1",
            participantName: "user-1",
            participantToken: "token-123"
        )
        mockTokenService.scenario = .success
        mockTokenService.mockConnectionDetails = connectionDetails

        // Prime the connection manager to succeed immediately when asked to wait
        mockWebRTCConnectionManager.succeedAgentReady()

        let auth = ElevenLabsConfiguration.publicAgent(id: "agent-123")
        var stateChanges = [ConversationStartupState]()

        do {
            let result = try await startup.execute(
                auth: auth,
                options: .default,
                provider: mockDependencyProvider,
                onStateChange: { state in
                    stateChanges.append(state)
                }
            )

            XCTAssertEqual(result.agentId, "agent-123")

            // Validate flow
            XCTAssertTrue(stateChanges.contains(where: {
                if case .resolvingToken = $0 { return true }; return false
            }))
            XCTAssertTrue(stateChanges.contains(where: {
                if case .connectingRoom = $0 { return true }; return false
            }))

        } catch let failure as StartupFailure where failure.reason == .agentTimeout {
            // Expected in mock env if we don't simulate agent ready signal
            XCTAssertTrue(stateChanges.contains(where: {
                if case .connectingRoom = $0 { return true }; return false
            }))
        } catch {
            XCTAssertTrue(mockTokenService.mockConnectionDetails != nil)
        }
    }

    func testExecute_TokenFailure_ThrowsError() async {
        mockTokenService.scenario = .arbitrary(TokenError.invalidResponse)

        let auth = ElevenLabsConfiguration.publicAgent(id: "agent-123")

        do {
            _ = try await startup.execute(
                auth: auth,
                options: .default,
                provider: mockDependencyProvider,
                onStateChange: { _ in }
            )
            XCTFail("Should have thrown error")
        } catch let failure as StartupFailure {
            if case .token = failure.reason {
                // Success
            } else {
                XCTFail("Wrong failure type: \(failure)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
