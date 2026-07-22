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
//  STABILITY (see memory wander-gsloc-consistency):
//   • KEEP-ALIVE (A3): the rewriter is reactive — it only changes what the NEXT gs-loc query returns,
//     and iOS re-queries on its own schedule, so a one-shot push per teleport silently drifts back when
//     a later real query lands. We re-assert the current target on a timer so the fix HOLDS.
//   • THROTTLE: push() is called on every inject (continuous during Walk/Route), so immediate fires are
//     capped at ~1 Hz — iOS re-queries far slower, and faster pushes risk a read landing mid-write (the
//     two-writers backward-jump seen in the OTA-92 Error-12 joystick fix).
//   • JITTER (B3): a perfectly frozen pinpoint is a behavioral spoof tell; a small bounded offset makes
//     the spot breathe without ever drifting off target.
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

    /// Thread-safe snapshot of the coordinate currently being pushed, for the verification banner to
    /// compare against the phone's own Core Location fix. nil when not spoofing (reset / never pushed).
    /// `q.sync` is a short critical section; safe to call from the main thread.
    static var currentTargetSnapshot: (lat: Double, lng: Double)? {
        q.sync { currentTarget }
    }

    // MARK: - Keep-alive + jitter state

    /// Serial queue that owns `currentTarget`, the keep-alive timer, and `lastFireUptimeNs`, so a
    /// teleport push, the keep-alive tick, and reset can never race. Everything `_locked` runs only here.
    private static let q = DispatchQueue(label: "com.wander.gsloc")
    private static var currentTarget: (lat: Double, lng: Double)?
    private static var keepAliveTimer: DispatchSourceTimer?
    private static var lastFireUptimeNs: UInt64 = 0

    /// Minimum gap between IMMEDIATE fires (~1 Hz throttle). See the STABILITY note above.
    private static let pushThrottle: TimeInterval = 1.0
    /// Cadence at which the current target is re-asserted so the spoof holds between teleports.
    private static let keepAliveInterval: TimeInterval = 5.0
    /// Bounded anti-frozen jitter radius, in meters. Small enough to be invisible inside a PoGo
    /// interaction range; bounded (not a random walk) so it never drifts away from the target.
    private static let jitterRadiusMeters: Double = 2.0

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // The push is supposed to be intercepted locally by the proxy, so it resolves near-instantly.
        // A long timeout only matters when the proxy is OFF — and then a 5 s hang per push backs up the
        // ~1 Hz throttle. Fail fast instead so a misconfigured session degrades cleanly.
        cfg.timeoutIntervalForRequest = 1.5
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    /// Push the target to the gs-loc rewriter. Stores it as the current target (latest wins), fires a
    /// jittered update (throttled to ~1 Hz), and starts the keep-alive re-push so the spot holds between
    /// teleports. Safe from any thread; returns immediately.
    static func push(latitude: Double, longitude: Double) {
        q.async {
            currentTarget = (latitude, longitude)
            if lastFireUptimeNs == 0 || elapsed(since: lastFireUptimeNs) >= pushThrottle {
                sendCurrentTarget_locked()
            }
            startKeepAlive_locked()
        }
    }

    /// Stop spoofing and fall back to the REAL location: clears the target, stops the keep-alive, and
    /// tells the rewriter to pass Apple's response through untouched. Used by Stop, and fired when the
    /// mode turns on so the first thing you see is your true location — not the module's default.
    static func reset() {
        q.async {
            currentTarget = nil
            stopKeepAlive_locked()
            fire(queryItems: [URLQueryItem(name: "reset", value: "1")])
        }
    }

    // MARK: - Internals (run only on q)

    private static func sendCurrentTarget_locked() {
        guard let t = currentTarget else { return }
        let (jlat, jlng) = jittered(t.lat, t.lng)
        // %.6f (~0.1 m) avoids Double's scientific-notation form near lat/lng 0, which a downstream
        // string/regex parser could choke on.
        fire(queryItems: [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", jlat)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", jlng)),
        ])
        lastFireUptimeNs = DispatchTime.now().uptimeNanoseconds
    }

    private static func startKeepAlive_locked() {
        guard keepAliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + keepAliveInterval, repeating: keepAliveInterval)
        timer.setEventHandler {
            // Stop the moment spoofing ends or the mode is turned off — belt-and-suspenders alongside reset().
            guard enabled, currentTarget != nil else { stopKeepAlive_locked(); return }
            sendCurrentTarget_locked()
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private static func stopKeepAlive_locked() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private static func elapsed(since ns: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- ns) / 1_000_000_000
    }

    /// A small bounded offset around the true target (≤ `jitterRadiusMeters`). Longitude degrees shrink
    /// with latitude, hence the cos scaling; guarded near the poles where cos → 0.
    private static func jittered(_ lat: Double, _ lng: Double) -> (Double, Double) {
        let radius = Double.random(in: 0...jitterRadiusMeters)
        let angle = Double.random(in: 0..<(2 * Double.pi))
        let dLat = (radius * cos(angle)) / 111_111.0
        let cosLat = cos(lat * Double.pi / 180)
        let dLng = abs(cosLat) < 1e-6 ? 0 : (radius * sin(angle)) / (111_111.0 * cosLat)
        return (lat + dLat, lng + dLng)
    }

    private static func fire(queryItems: [URLQueryItem]) {
        guard var comps = URLComponents(string: setEndpoint) else { return }
        comps.queryItems = queryItems
        guard let url = comps.url else { return }
        session.dataTask(with: url).resume()
    }
}
