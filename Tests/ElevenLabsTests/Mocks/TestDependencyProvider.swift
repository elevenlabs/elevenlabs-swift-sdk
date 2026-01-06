@testable import ElevenLabs

@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    let logger: any Logging
    private let _conversationStartup: any ConversationStartup
    private let _tokenService: any TokenServicing
    private let _connectionManager: any ConnectionManaging
    let errorHandler: (Swift.Error?) -> Void

    init(
        tokenService: any TokenServicing,
        connectionManager: any ConnectionManaging,
        errorHandler: @Sendable @escaping (Swift.Error?) -> Void = { _ in }
    ) {
        _tokenService = tokenService
        _connectionManager = connectionManager
        self.errorHandler = errorHandler

        logger = SDKLogger(logLevel: .error)
        _conversationStartup = DefaultConversationStartup(logger: logger)

        _connectionManager.errorHandler = { [weak self] error in
            self?.errorHandler(error)
        }
    }

    var tokenService: any TokenServicing {
        get async { _tokenService }
    }

    var conversationStartup: any ConversationStartup {
        get async { _conversationStartup }
    }

    func connectionManager() async -> any ConnectionManaging {
        _connectionManager
    }
}
