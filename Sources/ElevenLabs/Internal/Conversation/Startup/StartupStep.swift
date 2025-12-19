import Foundation

/// Protocol for individual startup steps in the conversation initialization process.
/// Each step is responsible for a specific phase of the startup sequence.
@MainActor
protocol StartupStep {
    /// The name of this step for logging purposes
    var stepName: String { get }
    
    /// Execute the step
    /// - Throws: Any error that occurs during execution
    func execute() async throws
}

/// A startup step that can be retried with configurable delays
@MainActor
protocol RetryableStartupStep: StartupStep {
    /// The delays between retry attempts (empty = no retries)
    var retryDelays: [TimeInterval] { get }
    
    /// Execute a single attempt of the step
    /// - Throws: Any error that occurs during execution
    func executeAttempt() async throws
}

extension RetryableStartupStep {
    func execute() async throws {
        let delays = retryDelays.isEmpty ? [0] : retryDelays
        
        for (index, delay) in delays.enumerated() {
            let attemptNumber = index + 1
            
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            do {
                try await executeAttempt()
                return // Success!
            } catch {
                if attemptNumber == delays.count {
                    throw error // Last attempt failed
                }
                // Continue to next retry
            }
        }
    }
}
