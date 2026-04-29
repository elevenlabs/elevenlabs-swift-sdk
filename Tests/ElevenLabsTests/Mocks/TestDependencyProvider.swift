@testable import ElevenLabs

@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    let logger: any Logging
    private let _tokenService: any TokenServicing
    private let _connectionManager: any ConnectionManaging
    let errorHandler: ((Swift.Error?) -> Void)?

    init(
        tokenService: any TokenServicing,
        connectionManager: any ConnectionManaging,
        errorHandler: (@Sendable (Swift.Error?) -> Void)? = nil
    ) {
        _tokenService = tokenService
        _connectionManager = connectionManager
        self.errorHandler = errorHandler

        logger = SDKLogger(logLevel: .error)

        _connectionManager.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }
    }

    var tokenService: any TokenServicing {
        get async { _tokenService }
    }

    func connectionManager() async -> any ConnectionManaging {
        _connectionManager
    }
}
