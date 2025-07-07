import Foundation
import LiveKit

// MARK: - Protocols for Dependency Injection

@available(macOS 11.0, iOS 14.0, *)
public protocol ElevenLabsNetworkServiceProtocol: Sendable {
    func getLiveKitToken(config: ElevenLabsSDK.SessionConfig) async throws -> String
}

@available(macOS 11.0, iOS 14.0, *)
public protocol LiveKitConversationFactoryProtocol: Sendable {
    func createConversation(
        token: String,
        config: ElevenLabsSDK.SessionConfig,
        callbacks: ElevenLabsSDK.Callbacks,
        clientTools: ElevenLabsSDK.ClientTools?
    ) -> LiveKitConversationProtocol
}

@available(macOS 11.0, iOS 14.0, *)
public protocol LiveKitConversationProtocol: Sendable {
    func connect() async throws
    func sendContextualUpdate(_ text: String)
    func sendUserMessage(_ text: String?)
    func sendUserActivity()
    func endSession()
    func getId() -> String
    func getInputVolume() -> Float
    func getOutputVolume() -> Float
    func startRecording()
    func stopRecording()
    var conversationVolume: Float { get set }
    
    /// Get current input (user) audio level in real-time
    /// - Returns: Current input audio level (0.0 to 1.0)
    func getCurrentInputLevel() -> Float
    
    /// Get current output (agent) audio level in real-time
    /// - Returns: Current output audio level (0.0 to 1.0)
    func getCurrentOutputLevel() -> Float
    
    /// Get recent input level history for trend analysis
    /// - Returns: Array of recent input levels (newest last)
    func getInputLevelHistory() -> [Float]
    
    /// Get recent output level history for trend analysis
    /// - Returns: Array of recent output levels (newest last)
    func getOutputLevelHistory() -> [Float]
}

@available(macOS 11.0, iOS 14.0, *)
public protocol AudioSessionConfiguratorProtocol: Sendable {
    func configureAudioSession() throws
}
