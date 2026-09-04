import ElevenLabs
import Foundation
import XCTest

@MainActor
final class ConversationClientPublicTestSeamTests: XCTestCase {
    func testExternalTransportCanDriveClientStartup() async throws {
        let client = ConversationClient(dependencyProvider: PublicDependencyProvider())

        let result = try await client.startTextOnlyConversation(.publicAgent(id: "fake-agent"))

        XCTAssertEqual(result.callInfo, CallInfo(agentId: "fake-agent", conversationId: "fake-conversation"))
        XCTAssertEqual(client.state, .connected(result.callInfo))
    }
}

@MainActor
private final class PublicDependencyProvider: ConversationDependencyProvider {
    private let transport = PublicTransport()

    var webRTCConnectionManager: any WebRTCConnectionManaging { transport }
    var webSocketConnectionManager: any WebSocketConnectionManaging { transport }
}

@MainActor
private final class PublicTransport: WebRTCConnectionManaging, WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onDisconnected: (() async -> Void)?
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?
    var onTracksChanged: (@Sendable () -> Void)?

    func connect(
        auth: ConversationAuth.Voice,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult {
        result(agentId: auth.agentId)
    }

    func connect(
        auth: ConversationAuth.TextOnly,
        config: ConversationConfig,
        onStartupStateChange: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult {
        result(agentId: auth.agentId)
    }

    func disconnect() async {}
    func send(data: Data) async throws {}
    func setMicrophoneMuted(_ muted: Bool) async throws {}
    func setAgentMuted(_ muted: Bool) {}

    private func result(agentId: String) -> ConversationStartResult {
        ConversationStartResult(
            callInfo: CallInfo(agentId: agentId, conversationId: "fake-conversation"),
            metrics: .init(total: 0)
        )
    }
}
