//
//  GslocMode.swift
//  Wander
//
//  EXPERIMENTAL "PoGo (gs-loc) mode". Wander normally injects location over Apple's developer tunnel
//  (DtSimulateLocation), which locationd stamps isSimulatedBySoftware=true → Pokémon GO throws
//  "Failed to detect location (12)" on iOS 26.x. This mode takes a different path: instead of the dev
//  tunnel, Wander hands the target coordinate to a gs-loc / Wi-Fi-geolocation rewrite running inside a
//  proxy app the user has set up (Shadowrocket + the Wander gs-loc module). That rewrite poisons
//  Apple's network-positioning response so Core Location COMPUTES the fix through its normal pipeline —
//  and a computed fix reads isSimulatedBySoftware=FALSE (measured on iOS 26.4). PoGo accepts it.
//
//  Wander cannot run the proxy itself: MITM needs a Network Extension (NEPacketTunnelProvider), whose
//  entitlement is stripped when Wander is re-signed for free sideloading (same wall as the VPN). So we
//  borrow the proxy's entitlement — Wander only PUSHES the coordinate to it.
//
//  HOW THE PUSH WORKS: while the proxy VPN is active it routes all of Wander's traffic, so a request to
//  a made-up host the module intercepts (never actually leaves the device) lands in the rewriter's
//  persistent store. mekos2772's rewriter reads latitude/longitude from $persistentStore, so pushing
//  those keys re-points the spoof.
//
//  KNOWN LIMIT (do not oversell): gs-loc only steers NETWORK location. A strong real GPS fix overrides
//  it, so this is a desk / deep-indoor tool, not live outdoor walking. Off by default; useless without
//  the proxy + a trusted MITM CA installed by the user.
//
import Foundation

enum GslocMode {
    private static let defaultsKey = "gsloc_mode_enabled"

    /// Made-up host the Wander gs-loc module intercepts with an http-request script. The request is
    /// caught locally by the proxy and never hits the network.
    static let setEndpoint = "http://wander.gsloc/set"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    /// Fire-and-forget push of the target coordinate to the proxy's gs-loc rewriter. Safe from any
    /// thread; returns immediately. No-op error handling — if the proxy isn't running the request just
    /// fails silently (the spoof simply won't move, which the user sees in Apple Maps / the diagnostic).
    static func push(latitude: Double, longitude: Double) {
        // %.6f (~0.1 m) avoids Double's scientific-notation form near lat/lng 0, which a downstream
        // string/regex parser could choke on.
        fire(queryItems: [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", longitude)),
        ])
    }

    /// Stop spoofing and fall back to the REAL location: tells the proxy rewriter to pass Apple's
    /// location response through untouched. Used by Stop, and fired when the mode turns on so the first
    /// thing you see is your true location — not the module's default (Apple Park).
    static func reset() {
        fire(queryItems: [URLQueryItem(name: "reset", value: "1")])
    }

    private static func fire(queryItems: [URLQueryItem]) {
        guard var comps = URLComponents(string: setEndpoint) else { return }
        comps.queryItems = queryItems
        guard let url = comps.url else { return }
        session.dataTask(with: url).resume()
    }
}
