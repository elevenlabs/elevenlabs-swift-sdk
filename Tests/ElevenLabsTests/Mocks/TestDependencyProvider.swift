@testable import ElevenLabs

@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    let logger: any Logging
    private let _tokenService: any TokenServicing
    private let _webRTCConnectionManager: any WebRTCConnectionManaging
    private let _webSocketConnectionManager: any WebSocketConnectionManaging
    let errorHandler: ((Swift.Error?) -> Void)?

    init(
        tokenService: any TokenServicing,
        webRTCConnectionManager: any WebRTCConnectionManaging,
        webSocketConnectionManager: any WebSocketConnectionManaging = MockWebSocketConnectionManager(),
        errorHandler: (@Sendable (Swift.Error?) -> Void)? = nil
    ) {
        _tokenService = tokenService
        _webRTCConnectionManager = webRTCConnectionManager
        _webSocketConnectionManager = webSocketConnectionManager
        self.errorHandler = errorHandler

        logger = SDKLogger(logLevel: .error)

        _webRTCConnectionManager.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }
        _webSocketConnectionManager.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }
    }

    var tokenService: any TokenServicing {
        get async { _tokenService }
    }

    func webRTCConnectionManager() async -> any WebRTCConnectionManaging {
        _webRTCConnectionManager
    }

    func webSocketConnectionManager() async -> any WebSocketConnectionManaging {
        _webSocketConnectionManager
    }
}
