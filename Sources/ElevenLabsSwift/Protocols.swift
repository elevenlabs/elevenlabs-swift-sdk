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
}

@available(macOS 11.0, iOS 14.0, *)
public protocol AudioSessionConfiguratorProtocol: Sendable {
    func configureAudioSession() throws
} 