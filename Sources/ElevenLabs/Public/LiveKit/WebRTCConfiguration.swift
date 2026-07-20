/// Controls how the SDK establishes WebRTC connections.
///
/// The default configuration gathers all ICE candidate types. Use ``Strategy/relayOnly``
/// to restrict connections to TURN relays.
public struct WebRTCConfiguration: Sendable {
    /// Describes how ICE transport candidates should be gathered.
    public enum Strategy: Sendable, Equatable {
        /// Gather all candidate types.
        case automatic
        /// Force TURN relay candidates only.
        case relayOnly
    }

    /// The strategy to use for ICE gathering. Defaults to ``Strategy/automatic``.
    public var strategy: Strategy

    public init(strategy: Strategy = .automatic) {
        self.strategy = strategy
    }

    /// Default configuration using automatic ICE candidate gathering.
    public static let `default` = WebRTCConfiguration()
}
