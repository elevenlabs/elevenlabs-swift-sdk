import Foundation
import LiveKit

/// Step responsible for sending conversation initialization with retry logic
@MainActor
final class ConversationInitStep: RetryableStartupStep {
    let stepName = "Conversation Init"
    
    let retryDelays: [TimeInterval]
    
    private let connectionManager: any ConnectionManaging
    private let config: ConversationConfig
    private let logger: any Logging
    private let onAttempt: (Int) -> Void
    
    
    init(
        connectionManager: any ConnectionManaging,
        config: ConversationConfig,
        retryDelays: [TimeInterval],
        logger: any Logging,
        onAttempt: @escaping (Int) -> Void
    ) {
        self.connectionManager = connectionManager
        self.config = config
        self.retryDelays = retryDelays
        self.logger = logger
        self.onAttempt = onAttempt
    }
    
    private(set) var attemptsMade = 0
    
    func executeAttempt() async throws {
        attemptsMade += 1
        onAttempt(attemptsMade)
        
        do {
            let initEvent = ConversationInitEvent(config: config)
            let data = try EventSerializer.serializeOutgoingEvent(.conversationInit(initEvent))
            
            let options = DataPublishOptions(reliable: true)
            try await connectionManager.publish(data: data, options: options)
            
            logger.debug("Conversation init attempt \(attemptsMade) sent")
        } catch let error as ConversationError {
            throw error
        } catch {
            logger.warning("Attempt \(attemptsMade) failed: \(error.localizedDescription)")
            throw error
        }
    }
}
