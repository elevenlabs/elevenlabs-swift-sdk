@_spi(Testing) import ElevenLabs
import Foundation
import XCTest

@MainActor
final class ConversationClientTestingSPITests: XCTestCase {
    func testExternalTransportCanStartAClient() async throws {
        let client = ConversationClient(dependencyProvider: PublicDependencyProvider())

        let result = try await client.startTextOnlyConversation(.publicAgent(id: "fake-agent"))

        XCTAssertEqual(client.state, .connected(result.callInfo))
    }
}

@MainActor
private final class PublicDependencyProvider: ConversationDependencyProvider {
    private let transport = PublicTransport()

    var webRTCConnectionManager: any WebRTCConnectionManaging {
        transport
    }

    var webSocketConnectionManager: any WebSocketConnectionManaging {
        transport
    }
}

@MainActor
private final class PublicTransport: WebRTCConnectionManaging, WebSocketConnectionManaging {
    var onEventReceived: (@Sendable (IncomingEvent) -> Void)?
    var onDisconnected: (() async -> Void)?
    var errorHandler: ((Error?) -> Void)?
    var onRemoteSpeakingChanged: (@Sendable (Bool) -> Void)?
    var onTracksChanged: (@Sendable () -> Void)?
    var isMicrophoneMuted = false

    func connect(
        auth: ConversationAuth.Voice,
        config _: ConversationConfig,
        onStartupStateChange _: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult {
        result(agentId: auth.agentId)
    }

    func connect(
        auth: ConversationAuth.TextOnly,
        config _: ConversationConfig,
        onStartupStateChange _: @escaping (ConversationStartupState) -> Void
    ) async throws -> ConversationStartResult {
        result(agentId: auth.agentId)
    }

    func disconnect() async {}
    func send(data _: Data) async throws {}
    func setMicrophoneMuted(_: Bool) async throws {}
    func setAgentMuted(_: Bool) {}

    private func result(agentId: String) -> ConversationStartResult {
        ConversationStartResult(
            callInfo: CallInfo(agentId: agentId, conversationId: "fake-conversation"),
            metrics: .init(total: 0)
        )
    }
}
