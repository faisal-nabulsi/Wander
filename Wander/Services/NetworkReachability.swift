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

    /// True only when the device has ACTUAL internet — not merely a "satisfied" network path.
    /// NWPathMonitor reports Wander's own LocalDevVPN loopback tunnel as satisfied even on Airplane
    /// Mode (no cellular/Wi-Fi), which would otherwise keep the online (Apple) map selected and blank
    /// it. We confirm real reachability with a tiny probe and drive the offline (cached-tile) map off
    /// this flag, so the main map stays usable — and spoofable — offline. Starts optimistic (`true`)
    /// so we never flash the offline map before the first probe returns.
    @Published private(set) var hasInternet: Bool = true
    nonisolated(unsafe) private(set) static var hasInternetSnapshot: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wander.reachability")
    private var probeTask: Task<Void, Never>?
    private var periodicProbeTask: Task<Void, Never>?
    private var probeFailStreak = 0

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // Underlying-transport check — see `isOnCellular` doc comment for the VPN/tunnel caveat.
            let onCellular = online
                && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
            NetworkReachability.isOnlineSnapshot = online
            NetworkReachability.isOnCellularSnapshot = onCellular
            // No path at all → definitely no internet; reflect it immediately (no probe needed).
            if !online { NetworkReachability.hasInternetSnapshot = false }
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isOnCellular != onCellular { self.isOnCellular = onCellular }
                self.refreshHasInternet(pathSatisfied: online)
            }
        }
        monitor.start(queue: queue)
        // Re-verify periodically so a transient probe failure — or internet returning/dropping
        // WITHOUT a path change (captive portal, router WAN loss) — self-corrects. Task.sleep pauses
        // while the app is suspended, so this only runs while the app is actually active.
        periodicProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                // 60s (was 15s): path changes already trigger an immediate re-probe, so this is only
                // a safety net for internet dropping/returning WITHOUT a path change. A longer interval
                // keeps the radio/battery cost negligible during a long background spoof session.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.refreshHasInternet(pathSatisfied: NetworkReachability.isOnlineSnapshot)
            }
        }
    }

    /// Confirm ACTUAL internet with a tiny probe when the path is satisfied (a satisfied path can be
    /// a VPN-only tunnel with no real connectivity — Wander's LocalDevVPN on Airplane Mode). Re-runs
    /// on every path change, so toggling Airplane Mode / Wi-Fi updates the flag promptly.
    @MainActor private func refreshHasInternet(pathSatisfied: Bool) {
        probeTask?.cancel()
        guard pathSatisfied else { probeFailStreak = 0; setHasInternet(false); return }
        probeTask = Task { [weak self] in
            let ok = await Self.probeInternet()
            if Task.isCancelled { return }
            await MainActor.run { self?.applyProbe(ok) }
        }
    }

    /// Success flips us online immediately; require TWO consecutive failures before switching a
    /// path-satisfied device to offline, so a single transient probe blip can't yank an online user
    /// onto the cached map.
    @MainActor private func applyProbe(_ ok: Bool) {
        if ok { probeFailStreak = 0; setHasInternet(true) }
        else { probeFailStreak += 1; if probeFailStreak >= 2 { setHasInternet(false) } }
    }

    @MainActor private func setHasInternet(_ value: Bool) {
        NetworkReachability.hasInternetSnapshot = value
        if hasInternet != value { hasInternet = value }
    }

    /// Lightweight reachability probe to Apple's captive-portal endpoint (built for exactly this,
    /// fast, no auth). A LocalDevVPN-only path on Airplane Mode fails it; real Wi-Fi/cellular passes.
    private static func probeInternet() async -> Bool {
        if await probeEndpoint("https://captive.apple.com/hotspot-detect.html", expectBody: "Success") {
            return true
        }
        // Fallback: some networks block/redirect Apple's captive endpoint, which would permanently
        // strand an online user on the cached/offline map. A generic 204 endpoint confirms real
        // connectivity independently, so a single blocked host can't cause a false "offline".
        return await probeEndpoint("https://www.gstatic.com/generate_204", expectBody: nil)
    }

    private static func probeEndpoint(_ urlString: String, expectBody: String?) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.setValue("Wander", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            if let expectBody {
                return http.statusCode == 200 && (String(data: data, encoding: .utf8)?.contains(expectBody) ?? false)
            }
            return (200...299).contains(http.statusCode)   // generate_204 → 204
        } catch { return false }
    }
}
