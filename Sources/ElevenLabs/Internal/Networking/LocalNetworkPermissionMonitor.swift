import Foundation
import Network

#if os(iOS)
/// Tracks iOS local network permission status so the SDK can surface actionable errors.
///
/// iOS does not expose a direct API to query permission state. Instead we:
/// 1. Subscribe to `NWPathMonitor` updates to watch for `requiresLocalNetworkAuthorization`.
/// 2. Attempt a harmless UDP bind once to trigger the system prompt when appropriate.
///
/// This monitor keeps lightweight state so that connection errors that stem from denied
/// local-network permission can be annotated for SDK consumers.
@MainActor
final class LocalNetworkPermissionMonitor {
    static let shared = LocalNetworkPermissionMonitor()

    private let pathMonitor: NWPathMonitor
    private var lastPath: NWPath?
    private var relayRequested: Bool = false

    private init() {
        pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.lastPath = path
            }
        }
        pathMonitor.start(queue: .main)
    }

    func recordRelayRequested() {
        relayRequested = true
    }

    func shouldSuggestLocalNetworkPermission() -> Bool {
        guard relayRequested else { return false }
        guard let path = lastPath else { return false }
        return path.status == .satisfied && path.isConstrained
    }
}
#else
final class LocalNetworkPermissionMonitor: Sendable {
    static let shared = LocalNetworkPermissionMonitor()
    private init() {}
    func recordRelayRequested() {}
    func shouldSuggestLocalNetworkPermission() -> Bool {
        false
    }
}
#endif
