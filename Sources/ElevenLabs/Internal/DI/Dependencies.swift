import Foundation
import LiveKit

@MainActor
protocol ConversationDependencyProvider: AnyObject {
    var logger: any Logging { get }
    var webRTCConnectionManager: any WebRTCConnectionManaging { get }
    var webSocketConnectionManager: any WebSocketConnectionManaging { get }
}

@MainActor
final class Dependencies: ConversationDependencyProvider {
    let webRTCConnectionManager: any WebRTCConnectionManaging

    let webSocketConnectionManager: any WebSocketConnectionManaging

    let logger: any Logging

    init(logLevel: LogLevel = .warning) {
        let tokenService: any TokenServicing = TokenService()
        logger = SDKLogger(levelOverride: logLevel)
        // Only the dedicated `.debugWithRTC` tier forwards LiveKit + underlying
        // WebRTC logs (ICE server list, candidate gathering, TURN allocation).
        // Kept off `.debug`/`.trace` since the RTC firehose is very noisy.
        if logLevel.forwardsRTCLogs {
            LiveKitSDK.setLogger(OSLogger(minLevel: .debug, rtc: true))
        }
        webRTCConnectionManager = WebRTCConnectionManager(logger: logger, tokenService: tokenService)
        webSocketConnectionManager = WebSocketConnectionManager(logger: logger)
    }
}
