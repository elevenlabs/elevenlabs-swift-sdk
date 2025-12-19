@testable import ElevenLabs

@MainActor
final class TestDependencyProvider: ConversationDependencyProvider {
    var logger: any Logging
    var conversationStartup: any ConversationStartup
    
    var tokenService: any TokenServicing
    var connectionManager: any ConnectionManaging
    var errorHandler: (Swift.Error?) -> Void

    init(
        tokenService: any TokenServicing,
        connectionManager: any ConnectionManaging,
        errorHandler: @Sendable @escaping (Swift.Error?) -> Void = { _ in }
    ) {
        self.tokenService = tokenService
        self.connectionManager = connectionManager
        self.errorHandler = errorHandler
        
        // Initialize with minimal defaults for tests that don't need them
        self.logger = SDKLogger(logLevel: .error)
        self.conversationStartup = DefaultConversationStartup(logger: self.logger)
        
        self.connectionManager.errorHandler = { [weak self] error in
            self?.errorHandler(error)
        }
    }
}
