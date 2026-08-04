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
//  HOW THE PUSH WORKS: while the proxy VPN is active it routes all of Wander's traffic, so a control
//  request the module intercepts lands in the rewriter's persistent store. mekos2772's rewriter reads
//  latitude/longitude from $persistentStore, so pushing those keys re-points the spoof.
//
//  TWO CONTROL CHANNELS (see GslocChannel): the original channel is a made-up HOST, which a proxy can only
//  catch through a [Rule] — and rules only fire while Global Routing is Proxy/Config, which proxy updates
//  silently reset to Direct. The newer channel is a fake PATH on a host the module already decrypts, so it
//  needs no rule at all. We push on the new one and fall back to the old, because a user still running an
//  older imported config has ONLY the old one.
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

/// The two control channels a Wander proxy config can answer on. Both carry the SAME contract — `…/set`
/// steers the spoof, `…/probe` answers `{"ok":true}` — what differs is what the proxy needs in order to
/// catch the request at all.
enum GslocChannel: Sendable {
    /// PREFERRED. A fake PATH on a REAL host the module already MITMs. A rewrite matched on the URL needs
    /// no `[Rule]` section, and rules are exactly what breaks: a Shadowrocket update periodically resets
    /// Global Routing to Direct, rules stop firing, and the spoof dies with no visible cause — the single
    /// biggest support burden this mode has.
    case modern
    /// LEGACY. A made-up host that resolves nowhere, so it is reachable ONLY through a `[Rule]` the proxy
    /// matches. Every config imported before the path move has only this one, so we keep pushing to it as a
    /// fallback — dropping it would silently kill working setups mid-session.
    case legacy

    var setEndpoint: String {
        switch self {
        case .modern: return "https://gs-loc.apple.com/wander/set"
        case .legacy: return "http://wander.gsloc/set"
        }
    }

    var probeEndpoint: String {
        switch self {
        case .modern: return "https://gs-loc.apple.com/wander/probe"
        case .legacy: return "http://wander.gsloc/probe"
        }
    }

    /// New first, old second. A config that answers both should be driven on the rule-free channel.
    static let preferenceOrder: [GslocChannel] = [.modern, .legacy]
}

enum GslocMode {
    /// UserDefaults key backing `enabled`. Exposed (not private) so movement/teleport views can bind an
    /// `@AppStorage(GslocMode.defaultsKey)` to it and react the instant PoGo mode is toggled — the same
    /// store `enabled` reads/writes, so the two can't disagree.
    static let defaultsKey = "gsloc_mode_enabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            // Toggling the mode is the moment a user has most likely just re-imported a proxy config, so
            // throw away what we learned about which channel answers and re-discover from the top. Being
            // pinned to the legacy channel after an upgrade would look exactly like "the update broke it".
            forgetChannel()
        }
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

    /// Ceiling for ONE channel attempt. The request is supposed to be caught locally by the proxy, so a slow
    /// attempt is a failed attempt — and the fallback attempt is queued behind it, so this is also how long
    /// a teleport can sit on a dead channel before the other one is tried.
    private static let attemptTimeout: TimeInterval = 2.0

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // Every request sets its own `timeoutInterval` (see attemptTimeout); this is the backstop. A long
        // timeout only matters when the proxy is OFF — and then a multi-second hang per push backs up the
        // ~1 Hz throttle. Fail fast instead so a misconfigured session degrades cleanly.
        cfg.timeoutIntervalForRequest = attemptTimeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - Channel selection (which endpoint this device's proxy config answers on)

    private static let channelLock = NSLock()
    /// The channel that last answered, or nil if we haven't learned it yet this run. Guarded by
    /// `channelLock` because it's touched from URLSession completion handlers (arbitrary threads), the push
    /// queue, and the Spoof Doctor on the main actor.
    ///
    /// IN-MEMORY ON PURPOSE — never persisted. A user who re-imports a newer proxy config must not stay
    /// pinned to the legacy channel forever, so the memory dies with the process, and `enabled`/`reset()`
    /// clear it at every point where the config plausibly changed under us.
    nonisolated(unsafe) private static var learnedChannel: GslocChannel?

    /// The channel that answered most recently this run, if any.
    static var preferredChannel: GslocChannel? {
        channelLock.lock(); defer { channelLock.unlock() }
        return learnedChannel
    }

    /// Record a channel that just answered, so the next push doesn't pay for a doomed first attempt. The
    /// Spoof Doctor writes here too — one "Check my setup" run teaches the teleport path which one to use.
    static func rememberChannel(_ channel: GslocChannel) {
        channelLock.lock(); defer { channelLock.unlock() }
        learnedChannel = channel
    }

    /// Drop what we learned so the next attempt starts from the NEW channel again.
    static func forgetChannel() {
        channelLock.lock(); defer { channelLock.unlock() }
        learnedChannel = nil
    }

    /// Channels to try, in order: the learned one first (if any), then the rest. The others are ALWAYS kept
    /// as fallbacks rather than dropped — a config can change mid-run (a re-import, or the user flipping
    /// Global Routing back), and re-learning beats going dead until the next launch.
    static func channelAttemptOrder() -> [GslocChannel] {
        guard let learned = preferredChannel else { return GslocChannel.preferenceOrder }
        return [learned] + GslocChannel.preferenceOrder.filter { $0 != learned }
    }

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
            // reset() marks every session boundary (Stop, mode turned on, proxy just connected), which is
            // also where a config swap would have happened — so re-discover the channel from the top rather
            // than trusting a guess made before the swap.
            forgetChannel()
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
        fire(queryItems: queryItems, channels: channelAttemptOrder()[...])
    }

    /// Send one control request down the first channel in `channels`; on failure, walk to the next one.
    /// Fire-and-forget from the caller's side — nothing here blocks the teleport, the fallback just lands a
    /// couple of seconds later.
    ///
    /// FAILURE = transport error, timeout, or any non-2xx. The non-2xx case is the one that matters: when
    /// the proxy isn't rewriting the new channel, the request reaches the real host and comes back 404, and
    /// that 404 is precisely the signal "this config doesn't know the new path — use the old one".
    ///
    /// TRADE-OFF that comes with a real host: an un-intercepted new-channel attempt actually leaves the
    /// device, carrying the TARGET coordinate (never the user's real one) to Apple, where it 404s. The old
    /// channel couldn't leak because its host resolves nowhere. That's the price of dropping the [Rule]
    /// requirement; pinning keeps it to one attempt per session boundary on a legacy-only config, not one
    /// per teleport.
    private static func fire(queryItems: [URLQueryItem], channels: ArraySlice<GslocChannel>) {
        guard let channel = channels.first else {
            // Nothing answered. Deliberately do NOT pin anything: the proxy being off looks the same as a
            // config that speaks neither channel, and pinning on an outage would outlive it.
            forgetChannel()
            return
        }
        guard var comps = URLComponents(string: channel.setEndpoint) else { return }
        comps.queryItems = queryItems
        guard let url = comps.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = attemptTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session.dataTask(with: request) { _, response, error in
            let answered = error == nil
                && ((response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false)
            if answered {
                rememberChannel(channel)
            } else {
                fire(queryItems: queryItems, channels: channels.dropFirst())
            }
        }.resume()
    }
}
