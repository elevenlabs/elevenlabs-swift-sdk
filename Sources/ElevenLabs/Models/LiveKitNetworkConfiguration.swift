import Foundation
import LiveKit

/// Controls how the SDK establishes LiveKit peer connections.
///
/// The default configuration uses automatic ICE candidate gathering (``Strategy/automatic``)
/// which allows direct peer-to-peer connections when possible, falling back to TURN relays as needed.
/// You can force TURN-only connectivity (``Strategy/relayOnly``) to avoid the iOS local network
/// permission prompt, or provide a fully custom transport policy and ICE server list if needed.
public struct LiveKitNetworkConfiguration: Sendable {
    /// Describes how ICE transport candidates should be gathered.
    public enum Strategy: Sendable, Equatable {
        /// Use LiveKit/WebRTC defaults (gather all candidate types).
        case automatic
        /// Force TURN relay candidates only.
        case relayOnly
        /// Provide a specific ``IceTransportPolicy``.
        case custom(IceTransportPolicy)
    }

    /// The strategy to use for ICE gathering. Defaults to ``Strategy/automatic``.
    public var strategy: Strategy

    /// Optional custom ICE servers to use instead of those supplied by the ElevenLabs backend.
    public var customIceServers: [IceServer]

    public init(strategy: Strategy = .automatic, customIceServers: [IceServer] = []) {
        self.strategy = strategy
        self.customIceServers = customIceServers
    }

    /// Default configuration (automatic ICE candidate gathering, no custom ICE servers).
    public static let `default` = LiveKitNetworkConfiguration()
}

extension LiveKitNetworkConfiguration {
    var resolvedIceTransportPolicy: IceTransportPolicy {
        switch strategy {
        case .automatic:
            .all
        case .relayOnly:
            .relay
        case let .custom(policy):
            policy
        }
    }

    var requiresCustomConnectOptions: Bool {
        strategy != .automatic || !customIceServers.isEmpty
    }

    func makeConnectOptions() -> ConnectOptions? {
        guard requiresCustomConnectOptions else {
            return nil
        }

        let policy = resolvedIceTransportPolicy
        #if os(iOS)
        if policy == .relay {
            LocalNetworkPermissionMonitor.shared.recordRelayRequested()
        }
        #endif

        return ConnectOptions(
            iceServers: customIceServers,
            iceTransportPolicy: policy
        )
    }
}
