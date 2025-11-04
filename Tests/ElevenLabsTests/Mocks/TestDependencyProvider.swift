@testable import ElevenLabs

@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    var tokenService: any TokenServicing
    var connectionManager: any ConnectionManaging
    var errorHandler: (Swift.Error?) -> Void

    init(
        tokenService: any TokenServicing,
        connectionManager: any ConnectionManaging,
        errorHandler: @Sendable @escaping (Swift.Error?) -> Void = { _ in },
    ) {
        self.tokenService = tokenService
        self.connectionManager = connectionManager
        self.errorHandler = errorHandler
        self.connectionManager.errorHandler = { [weak self] error in
            self?.errorHandler(error)
        }
    }
}
