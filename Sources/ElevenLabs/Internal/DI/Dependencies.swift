import Foundation

@_spi(Testing) @MainActor
public protocol ConversationDependencyProvider: AnyObject {
    var webRTCConnectionManager: any WebRTCConnectionManaging { get }
    var webSocketConnectionManager: any WebSocketConnectionManaging { get }
    func setRecordingAlwaysPreparedMode(_ enabled: Bool) async throws
}

/// Fake providers default to leaving the real audio pipeline alone.
extension ConversationDependencyProvider {
    @_spi(Testing) public func setRecordingAlwaysPreparedMode(_: Bool) async throws {}
}

/// A minimalistic dependency container for internal SDK use.
@MainActor
final class Dependencies: ConversationDependencyProvider {
    let webRTCConnectionManager: any WebRTCConnectionManaging
    let webSocketConnectionManager: any WebSocketConnectionManaging

    init(logLevel: LogLevel = .warning, endpoints: Endpoints = .production) {
        let logger = SDKLogger(logLevel: logLevel)
        webRTCConnectionManager = WebRTCConnectionManager(
            logger: logger,
            tokenService: TokenService(endpoints: endpoints),
            endpoints: endpoints
        )
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger, endpoints: endpoints)
    }

    func setRecordingAlwaysPreparedMode(_ enabled: Bool) async throws {
        try await ConversationAudioManager.setRecordingAlwaysPreparedMode(enabled)
    }
}
