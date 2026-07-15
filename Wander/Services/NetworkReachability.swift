//
//  NetworkReachability.swift
//  Wander
//
//  A tiny, app-wide connectivity flag backed by NWPathMonitor. Purely cosmetic: it lets the UI
//  show a subtle, non-nagging "Offline" hint so the app's calm empty states (a hidden weather
//  card, a globe that can't load, an empty raids board) read as intentional rather than broken.
//
//  It NEVER gates or blocks anything — teleport, joystick, and routes stay fully usable offline.
//  Nothing in the app should branch behaviour on this; it only drives an optional indicator.
//

import Foundation
import Network

@MainActor
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    /// True once the monitor has seen a satisfied path. Starts `true` so we never flash an
    /// "Offline" hint during the brief moment before the first path update arrives.
    @Published private(set) var isOnline: Bool = true

    /// True when the device's active internet path runs over cellular and NOT Wi-Fi.
    ///
    /// Reliability caveat (documented on purpose): the standalone iOS app runs its own
    /// LocalDevVPN tunnel (a `utun` interface), so we can NEVER use "is a VPN present?" to
    /// reason about the user's exposure — Wander's own tunnel looks identical to a privacy
    /// VPN. This flag deliberately does not care about VPNs at all. Instead it reads the
    /// *underlying* transport of the default path via `NWPathMonitor`:
    ///
    ///   `path.status == .satisfied && usesInterfaceType(.cellular) && !usesInterfaceType(.wifi)`
    ///
    /// Empirically, when a personal VPN (or Wander's tunnel) is up, iOS still reports the
    /// physical interface(s) backing the tunnel in `availableInterfaces` / `usesInterfaceType`,
    /// so a cellular-backed tunnel still reports `.cellular` here and a Wi-Fi-backed one reports
    /// `.wifi`. This is best-effort: iOS gives no *guaranteed* contract that the real transport
    /// is always surfaced through a tunnel, and on a brief transition (e.g. Wi-Fi dropping to
    /// cellular) the reported interfaces can lag by a path update. We therefore treat this as an
    /// advisory signal only — it drives a coaching hint, never gates spoofing. The `!wifi` clause
    /// makes us conservative: if Wi-Fi is present at all we do NOT warn, so we never nag a user
    /// who is actually on Wi-Fi even if cellular is also listed as available.
    @Published private(set) var isOnCellular: Bool = false

    /// A nonisolated, thread-safe mirror of `isOnline` for callers that run off the main actor
    /// (e.g. `WanderTileOverlay.loadTile`, invoked on a background tile-loading queue) and can't
    /// hop to the main actor synchronously. Kept in sync from the same path-update handler.
    nonisolated(unsafe) private(set) static var isOnlineSnapshot: Bool = true

    /// Nonisolated mirror of `isOnCellular` for off-main-actor reads (same rationale as
    /// `isOnlineSnapshot`). Lets the spoof-start funnel decide synchronously without hopping.
    nonisolated(unsafe) private(set) static var isOnCellularSnapshot: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wander.reachability")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // Underlying-transport check — see `isOnCellular` doc comment for the VPN/tunnel caveat.
            let onCellular = online
                && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
            NetworkReachability.isOnlineSnapshot = online
            NetworkReachability.isOnCellularSnapshot = onCellular
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isOnCellular != onCellular { self.isOnCellular = onCellular }
            }
        }
        monitor.start(queue: queue)
    }
}
