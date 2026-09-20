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
//  ── TWO PLANES, AND ONLY ONE OF THEM IS OURS ────────────────────────────────────────────────────────
//  Everything below only makes sense once these are kept apart:
//
//   • CONTROL PLANE (ours, end to end): Wander → HTTP → the proxy's control script → $persistentStore.
//     We can retry this at any rate we like.
//   • DELIVERY PLANE (not ours at all): locationd decides, on its own schedule, to POST /clls/wloc; the
//     response rewriter fires; locationd computes a new fix. Nothing in this file can trigger that. The
//     only reliable trigger is the user power-cycling Location Services (off a full ~10 s, then on), or a
//     reboot on iOS 26+. No app or Shortcut can flip that switch.
//
//  WHAT THE KEEP-ALIVE IS AND IS NOT. It re-asserts the current target on a timer. The failure it
//  repairs is a CONTROL-PLANE one: a push that never landed — a 2 s timeout, the app suspended mid-request,
//  Global Routing momentarily Direct, or the store cleared by a proxy restart — which leaves the store
//  holding the PREVIOUS coordinate, so the next gs-loc query (whenever it comes) is answered with a stale
//  spot. Retrying is the only cure, because we get no delivery receipt.
//  It is NOT an anti-snap-back or anti-drift feature, and must never be sold as one. The stored value has
//  NO TTL — the rewriter re-reads it on every intercepted response — so it cannot go stale on its own, and
//  re-pushing a coordinate that is already in the store is a no-op on the wire. Re-pushing therefore does
//  nothing at all for the two failures users actually report:
//    – GPS OVERRIDE: locationd fuses sources and prefers a good GNSS fix (~5 m) over a Wi-Fi one
//      (~25–39 m). Re-pushing changes what the network source SAYS, not which source WINS. Platform wall.
//    – CACHE-SNAP: iOS is serving a cached computed fix and has not re-queried. There is no query to
//      intercept. Only the Location Services power-cycle / reboot clears it.
//
//  OTHER STABILITY NOTES:
//   • THROTTLE: push() is called on every inject, so immediate fires are capped at ~1 Hz — iOS re-queries
//     far slower, and faster pushes risk a read landing mid-write (the two-writers backward-jump seen in
//     the OTA-92 Error-12 joystick fix). A throttled push now schedules a TRAILING fire instead of waiting
//     for the next keep-alive tick, so the newest target can never sit unsent for ~5 s.
//   • GENERATION GUARD: every push/reset bumps `generation`. In-flight control requests carry the
//     generation they were issued under and drop themselves if a newer write has superseded them, so a
//     late fallback attempt from an old teleport can never resurrect a stale coordinate. ONE authoritative
//     writer at a time — the same rule the OTA-92 fix imposed on the location stream.
//   • JITTER: a perfectly frozen pinpoint is a behavioral spoof tell; a small bounded offset makes the
//     spot breathe without ever drifting off target.
//
//  KNOWN LIMIT (do not oversell): gs-loc only steers NETWORK location, and only changes what the NEXT
//  gs-loc query returns. So it is ONE SPOT AT A TIME: every new coordinate needs the manual Location
//  Services flush before the phone reports it, which is why live movement (joystick, routes, auto-walk)
//  is structurally impossible on this path and is disabled in the UI. A strong real GPS fix overrides it
//  outright, so this is a desk / deep-indoor tool. Off by default; useless without the proxy + a trusted
//  MITM CA installed by the user.
//
import Foundation

extension Notification.Name {
    /// Posted (on the main queue) whenever `GslocMode.lastPushOutcome` CHANGES value, so a card can show
    /// an honest "your last teleport didn't land" row without polling. Never posted for an unchanged
    /// outcome, so a healthy keep-alive at 5 s doesn't spam the main queue.
    static let gslocPushOutcomeDidChange = Notification.Name("wander.gslocPushOutcomeDidChange")
}

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

    /// True when an UN-INTERCEPTED attempt on this channel actually leaves the device. The modern channel
    /// is a real, resolvable Apple host, so a miss carries the TARGET coordinate to Apple (where it 404s);
    /// the legacy host resolves nowhere, so a miss cannot leave. This is why unattended traffic
    /// (keep-alive ticks) is restricted — see `keepAliveChannels()`.
    var leaksWhenNotIntercepted: Bool {
        switch self {
        case .modern: return true
        case .legacy: return false
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
            recordOutcome(.unknown)
        }
    }

    /// EXPERIMENT — run BOTH engines at once instead of gs-loc replacing DVT.
    ///
    /// The two engines are mutually exclusive today only because `simulate_location` early-returns after
    /// the gs-loc push (IdeviceFFIBridge.swift). That is OUR gate, not a platform limit — nobody has ever
    /// actually run them together. The hypothesis: gs-loc ANCHORS Apple's network location at the target
    /// while DVT supplies smooth movement, so a player could joystick/route inside the GPS-vs-network
    /// coherence tolerance instead of being stuck teleporting.
    ///
    /// ⚠️ THE PRIOR IS NEGATIVE, and it must not be sold as promising. Deep research (2026-07-22, recorded
    /// in the `wander-wloc-protocol` memory) concluded a live DtSimulateLocation injection is a DEVICE-WIDE
    /// 🪦 DISPROVEN AND REMOVED 2026-08-10 — kept only as a permanent `false` so historical
    /// `ExperimentRecord`s still decode and so nothing accidentally revives it.
    ///
    /// The hypothesis: gs-loc anchors Apple's network location while DVT supplies smooth movement, so
    /// Pokémon GO would accept a moving fix. A controlled on-device A/B killed it. Holding the location
    /// constant at ONE coordinate (both sources agreeing), the tunnel's presence alone decided the
    /// outcome: tunnel on → flag TRUE → Error 12; tunnel off, SAME coordinate → flag FALSE → PoGo works.
    /// Error 12 tracks `isSimulatedBySoftware`, so pairing the tunnel with anything is pointless — the
    /// tunnel IS the rejected thing. See [[wander-mode-separation]] / [[wander-error12-network-location]].
    /// Do NOT re-add a toggle for this.
    static var dualEngine: Bool { false }

    /// Thread-safe snapshot of the coordinate currently being pushed, for the verification banner to
    /// compare against the phone's own Core Location fix. nil when not spoofing (reset / never pushed).
    /// `q.sync` is a short critical section; safe to call from the main thread.
    static var currentTargetSnapshot: (lat: Double, lng: Double)? {
        q.sync { currentTarget }
    }

    // MARK: - Push outcome (the honesty channel)

    /// What became of the most recent control write. gs-loc gives us no delivery receipt, and for a long
    /// time every gs-loc write reported success unconditionally: `simulate_location` recorded
    /// `TunnelInjectStatus.record(success: true)` and the Spoof Timeline recorded `accepted: true` BY
    /// CONSTRUCTION, so a teleport that never reached the proxy was indistinguishable from one that landed.
    /// Callers sit on the serial location queue and must never WAIT for a push, so they read the LAST
    /// KNOWN outcome instead: it lags by one write, which is honest, cheap and non-blocking.
    enum PushOutcome: Equatable, Sendable {
        /// Nothing pushed yet this run — no evidence either way. Treated as "not a failure".
        case unknown
        /// A channel answered `{"ok":true}` and, for a coordinate write, read the value back correctly.
        case landed
        /// NO channel answered: the proxy is disconnected, Global Routing was reset to Direct, the module
        /// isn't imported, or another VPN holds the slot.
        case noProxy
        /// A channel ANSWERED but a read-back proved the proxy did not store the value. That is the exact
        /// signature of a STALE cached control script: the proxy replies 200 to everything while the spoof
        /// stays frozen at the previous target. Not fixable from inside the app — the config must be
        /// re-imported (which is also why the served config URLs are cache-busted).
        case notStored

        /// Whether this outcome should be logged as an accepted write. `.unknown` counts as accepted —
        /// the first write of a run has produced no evidence, and calling it a failure would paint every
        /// fresh session amber.
        var looksAccepted: Bool { self != .noProxy && self != .notStored }
    }

    private static let outcomeLock = NSLock()
    /// Guarded by `outcomeLock`, which is only ever held for a handful of instructions — never across
    /// I/O — so `lastPushOutcome` is safe to read from the serial location command queue.
    nonisolated(unsafe) private static var _lastPushOutcome: PushOutcome = .unknown
    nonisolated(unsafe) private static var _lastPushOutcomeAt: Date?

    /// The most recent control-write outcome. Safe from any thread.
    static var lastPushOutcome: PushOutcome {
        outcomeLock.lock(); defer { outcomeLock.unlock() }
        return _lastPushOutcome
    }

    /// When `lastPushOutcome` was recorded, for "as of 12 s ago" style copy. nil until the first write.
    static var lastPushOutcomeAt: Date? {
        outcomeLock.lock(); defer { outcomeLock.unlock() }
        return _lastPushOutcomeAt
    }

    private static func recordOutcome(_ outcome: PushOutcome) {
        outcomeLock.lock()
        let changed = _lastPushOutcome != outcome
        _lastPushOutcome = outcome
        _lastPushOutcomeAt = outcome == .unknown ? nil : Date()
        outcomeLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .gslocPushOutcomeDidChange, object: nil)
        }
    }

    // MARK: - Keep-alive + jitter state

    /// Serial queue that owns `currentTarget`, the timers, `generation` and `lastFireUptimeNs`, so a
    /// teleport push, a keep-alive tick, a reset retry and a completion handler can never race.
    /// Everything `_locked` runs only here.
    private static let q = DispatchQueue(label: "com.wander.gsloc")
    private static var currentTarget: (lat: Double, lng: Double)?
    private static var keepAliveTimer: DispatchSourceTimer?
    private static var trailingTimer: DispatchSourceTimer?
    private static var resetRetryTimer: DispatchSourceTimer?
    private static var lastFireUptimeNs: UInt64 = 0

    /// Bumped by every push and every reset. An in-flight control request carries the generation it was
    /// issued under; when it comes back it drops itself if `generation` has moved on. That is what keeps
    /// exactly ONE authoritative writer on the control channel — the OTA-92 rule, applied here.
    private static var generation: UInt64 = 0
    /// Consecutive keep-alive ticks that reached nobody. Drives the cadence backoff below.
    private static var keepAliveFailures = 0
    /// Live keep-alive cadence (grows under backoff, snaps back on the first success).
    private static var keepAliveIntervalNow: TimeInterval = 5.0
    /// Reset attempts still available on the current un-spoof chain. See `reset()`.
    private static var resetAttemptsLeft = 0

    /// Minimum gap between IMMEDIATE fires (~1 Hz throttle). See the STABILITY note above.
    private static let pushThrottle: TimeInterval = 1.0
    /// Baseline cadence at which the current target is re-asserted, so a push that never landed is
    /// retried rather than lost. NOT a stickiness dial — see the header.
    private static let keepAliveInterval: TimeInterval = 5.0
    /// Ceiling for the backed-off keep-alive cadence. While nothing is answering, an un-intercepted
    /// modern-channel attempt is a real coordinate leak to Apple, so a dead proxy must cost ~1 request a
    /// minute, not 12.
    private static let keepAliveMaxInterval: TimeInterval = 60.0
    /// Bounded anti-frozen jitter radius, in meters. Small enough to be invisible inside a PoGo
    /// interaction range; bounded (not a random walk) so it never drifts away from the target.
    private static let jitterRadiusMeters: Double = 2.0
    /// How far the read-back may differ from what we pushed and still count as stored. Generous next to
    /// the ≤2 m jitter and %.6f rounding, tiny next to "the store still holds the previous city".
    private static let storedMatchToleranceMeters: Double = 25.0
    /// Attempts on an un-spoof chain, and the gap between them. See `reset()`.
    private static let resetMaxAttempts = 4
    private static let resetRetryDelay: TimeInterval = 4.0

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
    ///
    /// This full walk belongs to USER-INITIATED writes only. Discovery costs a request that may leave the
    /// device (see `GslocChannel.leaksWhenNotIntercepted`), so a person doing something is the right moment
    /// to pay it; an unattended timer is not.
    static func channelAttemptOrder() -> [GslocChannel] {
        guard let learned = preferredChannel else { return GslocChannel.preferenceOrder }
        return [learned] + GslocChannel.preferenceOrder.filter { $0 != learned }
    }

    /// Channels a KEEP-ALIVE tick may use — deliberately narrower than `channelAttemptOrder()`.
    ///
    /// While a channel is LEARNED it is being intercepted, so re-asserting on it stays inside the proxy and
    /// costs nothing. When nothing has been learned we fall back to the LEGACY channel ALONE, because it
    /// resolves nowhere and therefore cannot leave the device. Without this, a proxy that is simply off
    /// meant the timer re-attempted the modern channel — a real, resolvable Apple host — roughly twelve
    /// times a minute, indefinitely, each attempt carrying the spoof target to Apple. Re-discovery still
    /// happens, just on the next thing the USER does.
    private static func keepAliveChannels() -> [GslocChannel] {
        if let learned = preferredChannel { return [learned] }
        return GslocChannel.preferenceOrder.filter { !$0.leaksWhenNotIntercepted }
    }

    /// Push the target to the gs-loc rewriter. Stores it as the current target (latest wins), fires a
    /// jittered update (throttled to ~1 Hz, with a trailing fire if throttled), and starts the keep-alive
    /// re-push so a write that never landed is retried. Safe from any thread; returns immediately.
    static func push(latitude: Double, longitude: Double) {
        q.async {
            currentTarget = (latitude, longitude)
            // A new target supersedes everything older: any in-flight fallback walk, any pending trailing
            // fire, and any un-spoof chain still retrying. One writer.
            generation &+= 1
            resetAttemptsLeft = 0
            cancelResetRetry_locked()
            cancelTrailing_locked()
            // A person just acted: go back to the fast cadence even if the proxy was failing a moment ago.
            keepAliveFailures = 0
            keepAliveIntervalNow = keepAliveInterval
            if lastFireUptimeNs == 0 || elapsed(since: lastFireUptimeNs) >= pushThrottle {
                sendCurrentTarget_locked(channels: channelAttemptOrder(), verifyStored: true)
            } else {
                // THROTTLED, NOT DROPPED. Without this the newest target waited for the next keep-alive
                // tick — up to ~5 s of the phone being steered to the previous spot.
                scheduleTrailingFire_locked()
            }
            startKeepAlive_locked()
        }
    }

    /// Stop spoofing and fall back to the REAL location: clears the target, stops the keep-alive, and
    /// tells the rewriter to pass Apple's response through untouched. Used by Stop, and fired when the
    /// mode turns on so the first thing you see is your true location — not the module's default.
    ///
    /// RETRIED, unlike before. The set path had a keep-alive but the un-spoof path was a single
    /// fire-and-forget GET: if it failed (proxy briefly down, routing Direct) the store kept
    /// `enabled=true` at the old coordinate, nothing was left to retry it, and `clear_simulated_location()`
    /// reported success anyway — so Stop / Panic / switching the mode off could all claim to have stopped
    /// while the phone stayed spoofed indefinitely. That is the privacy-relevant direction, so it is the
    /// one that now insists.
    static func reset() {
        q.async {
            currentTarget = nil
            generation &+= 1
            stopKeepAlive_locked()
            cancelTrailing_locked()
            cancelResetRetry_locked()
            // reset() marks every session boundary (Stop, mode turned on, proxy just connected), which is
            // also where a config swap would have happened — so re-discover the channel from the top rather
            // than trusting a guess made before the swap.
            forgetChannel()
            resetAttemptsLeft = resetMaxAttempts
            sendReset_locked()
        }
    }

    // MARK: - Internals (run only on q)

    private static func sendReset_locked() {
        guard resetAttemptsLeft > 0 else { recordOutcome(.noProxy); return }
        resetAttemptsLeft -= 1
        let gen = generation
        fire(queryItems: [URLQueryItem(name: "reset", value: "1")],
             channels: channelAttemptOrder()[...],
             generation: gen,
             // Confirm the un-spoof by reading the store back: after a reset the proxy must report
             // `target: null`. A 200 alone would be satisfied by a control script that answers everything
             // and stores nothing.
             // `answered` is load-bearing here. An un-answered probe also yields no target, and treating
             // that as "target is null" would report the un-spoof as confirmed on the strength of a
             // request that failed — the exact false reassurance this retry exists to remove.
             verify: { channel, done in
                 readBack(channel: channel) { probe in done(probe.answered && probe.lat == nil) }
             }) { result in
            guard gen == generation else { return }   // superseded by a new target or a newer reset
            switch result {
            case .landed:
                resetAttemptsLeft = 0
                recordOutcome(.landed)
            case .notStored:
                resetAttemptsLeft = 0   // retrying a stale control script just repeats the same lie
                recordOutcome(.notStored)
            case .noProxy:
                if resetAttemptsLeft > 0 {
                    scheduleResetRetry_locked(generation: gen)
                } else {
                    recordOutcome(.noProxy)
                }
            case .unknown:
                break   // `fire` never reports this; listed so the switch stays exhaustive.
            }
        }
    }

    private static func scheduleResetRetry_locked(generation gen: UInt64) {
        cancelResetRetry_locked()
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + resetRetryDelay)
        timer.setEventHandler {
            resetRetryTimer = nil
            guard gen == generation else { return }
            sendReset_locked()
        }
        resetRetryTimer = timer
        timer.resume()
    }

    private static func cancelResetRetry_locked() {
        resetRetryTimer?.cancel()
        resetRetryTimer = nil
    }

    private static func sendCurrentTarget_locked(channels: [GslocChannel], verifyStored: Bool) {
        guard let t = currentTarget, !channels.isEmpty else { return }
        let (jlat, jlng) = jittered(t.lat, t.lng)
        let gen = generation
        lastFireUptimeNs = DispatchTime.now().uptimeNanoseconds
        // %.6f (~0.1 m) avoids Double's scientific-notation form near lat/lng 0, which a downstream
        // string/regex parser could choke on.
        let items = [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", jlat)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", jlng)),
        ]
        // READ-BACK on user-initiated writes only. It is what catches a proxy running a STALE cached
        // control script: that script answers `{"ok":true}` to the modern channel while writing nothing,
        // so without a read-back the app pins to a dead channel, freezes the spoof at the previous target,
        // and reports success forever. Treating a failed read-back as a failed CHANNEL means the fallback
        // walk continues to the legacy channel, which on such a config is the one that actually works.
        // Keep-alive ticks skip it — they'd double the request rate to re-prove what the last user write
        // already proved.
        let verify: ChannelVerifier? = verifyStored
            ? { channel, done in
                readBack(channel: channel) { probe in
                    guard probe.answered, let lat = probe.lat, let lng = probe.lng else { done(false); return }
                    done(distanceMeters(lat, lng, jlat, jlng) <= storedMatchToleranceMeters)
                }
              }
            : nil
        fire(queryItems: items, channels: channels[...], generation: gen, verify: verify) { result in
            guard gen == generation else { return }
            recordOutcome(result)
            switch result {
            case .landed:
                noteKeepAliveSuccess_locked()
            case .noProxy, .notStored:
                noteKeepAliveFailure_locked()
            case .unknown:
                break   // `fire` never reports this; listed so the switch stays exhaustive.
            }
        }
    }

    /// Fire the newest target as soon as the ~1 Hz throttle allows. No generation guard is needed here:
    /// every push cancels this timer before deciding what to do, so a live trailing timer always belongs
    /// to the current generation, and it deliberately sends whatever `currentTarget` is at the moment it
    /// fires — the latest value, never the one that was pending when it was scheduled.
    private static func scheduleTrailingFire_locked() {
        guard trailingTimer == nil else { return }
        let delay = max(0, pushThrottle - elapsed(since: lastFireUptimeNs))
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            trailingTimer = nil
            guard enabled, currentTarget != nil else { return }
            sendCurrentTarget_locked(channels: channelAttemptOrder(), verifyStored: true)
        }
        trailingTimer = timer
        timer.resume()
    }

    private static func cancelTrailing_locked() {
        trailingTimer?.cancel()
        trailingTimer = nil
    }

    private static func startKeepAlive_locked() {
        armKeepAlive_locked()
    }

    private static func armKeepAlive_locked() {
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + keepAliveIntervalNow, repeating: keepAliveIntervalNow)
        timer.setEventHandler {
            // Stop the moment spoofing ends or the mode is turned off — belt-and-suspenders alongside reset().
            guard enabled, currentTarget != nil else { stopKeepAlive_locked(); return }
            sendCurrentTarget_locked(channels: keepAliveChannels(), verifyStored: false)
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private static func stopKeepAlive_locked() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private static func noteKeepAliveSuccess_locked() {
        guard keepAliveFailures != 0 || keepAliveIntervalNow != keepAliveInterval else { return }
        keepAliveFailures = 0
        keepAliveIntervalNow = keepAliveInterval
        if keepAliveTimer != nil { armKeepAlive_locked() }
    }

    /// Back the re-assert cadence off while nothing is answering: 5 s, 5, 10, 20, 40, 60 (cap). One blip
    /// costs nothing; a proxy that has been off for a minute stops costing a request every five seconds.
    /// The first success snaps it straight back.
    private static func noteKeepAliveFailure_locked() {
        keepAliveFailures += 1
        let steps = max(0, min(keepAliveFailures - 1, 6))
        let next = min(keepAliveMaxInterval, keepAliveInterval * pow(2, Double(steps)))
        guard next != keepAliveIntervalNow else { return }
        keepAliveIntervalNow = next
        if keepAliveTimer != nil { armKeepAlive_locked() }
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

    private static func distanceMeters(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let dLat = (lat1 - lat2) * 111_111.0
        let dLng = (lng1 - lng2) * 111_111.0 * cos(lat1 * Double.pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }

    // MARK: - Transport

    /// Asks one channel "did the value actually land?" and reports yes/no. The answer arrives from a
    /// URLSession callback, so the reply closure must outlive the call — hence `@escaping`.
    typealias ChannelVerifier = (GslocChannel, @escaping (Bool) -> Void) -> Void

    /// What a `/probe` came back with. The two facts are INDEPENDENT and must not be collapsed: a proxy
    /// that never answered and a proxy holding nothing both have no coordinate, but only one of them is
    /// evidence about the spoof.
    struct ProbeResult {
        /// The proxy answered `{"ok":true}`. False for any transport error, non-200, non-JSON or ok != true.
        let answered: Bool
        /// The coordinate the store is holding. Both nil when the store is empty, was reset, or unreadable.
        let lat: Double?
        let lng: Double?

        static let noAnswer = ProbeResult(answered: false, lat: nil, lng: nil)
    }

    /// GET `…/probe` on `channel` and report what the proxy says it is holding. This is the confirmation
    /// channel the control script has always exposed and nothing ever used.
    private static func readBack(channel: GslocChannel, completion: @escaping (ProbeResult) -> Void) {
        guard let url = URL(string: channel.probeEndpoint) else { completion(.noAnswer); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = attemptTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session.dataTask(with: request) { data, response, error in
            completion(parseProbe(data: data, response: response, error: error))
        }.resume()
    }

    /// Parse a `/probe` answer. Pure, so it is unit-testable without the network.
    static func parseProbe(data: Data?, response: URLResponse?, error: Error?) -> ProbeResult {
        guard error == nil,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["ok"] as? Bool) == true
        else { return .noAnswer }
        guard let target = json["target"] as? [String: Any],
              let lat = target["lat"] as? Double,
              let lng = target["lng"] as? Double,
              lat.isFinite, lng.isFinite
        else { return ProbeResult(answered: true, lat: nil, lng: nil) }
        return ProbeResult(answered: true, lat: lat, lng: lng)
    }

    /// Send one control request down the first channel in `channels`; on failure, walk to the next one.
    /// Fire-and-forget from the caller's side — nothing here blocks the teleport, the fallback just lands a
    /// couple of seconds later. `completion` always runs on `q`, exactly once.
    ///
    /// SUCCESS is now HTTP 200 **with a JSON body carrying `"ok": true`** — the same test the Spoof Doctor
    /// applies (`SpoofDoctor.interpretProbe`), shared rather than re-implemented so the teleport path and
    /// the diagnostic can never disagree about what "answered" means. A bare 2xx was too weak.
    ///
    /// FAILURE = transport error, timeout, a non-2xx, a body without `ok:true`, or (when `verify` is
    /// supplied) a read-back showing the value was not stored. The non-2xx case still matters: when the
    /// proxy isn't rewriting the new channel, the request reaches the real host and comes back 404, and
    /// that 404 is precisely the signal "this config doesn't know the new path — use the old one".
    ///
    /// TRADE-OFF that comes with a real host: an un-intercepted new-channel attempt actually leaves the
    /// device, carrying the TARGET coordinate (never the user's real one) to Apple, where it 404s. The old
    /// channel couldn't leak because its host resolves nowhere. That's the price of dropping the [Rule]
    /// requirement — and it is why unattended keep-alive ticks never walk to it (see `keepAliveChannels()`).
    private static func fire(queryItems: [URLQueryItem],
                             channels: ArraySlice<GslocChannel>,
                             generation gen: UInt64,
                             verify: ChannelVerifier? = nil,
                             sawAnswerWithoutStore: Bool = false,
                             completion: @escaping (PushOutcome) -> Void) {
        func giveUp() {
            // Nothing answered. Deliberately do NOT pin anything: the proxy being off looks the same as a
            // config that speaks neither channel, and pinning on an outage would outlive it.
            forgetChannel()
            q.async { completion(sawAnswerWithoutStore ? .notStored : .noProxy) }
        }
        func next(sawStale: Bool) {
            q.async {
                // GENERATION GUARD: a newer push/reset already owns the channel, so this walk is stale.
                // Continuing it would put an old coordinate into the store after the new one.
                guard gen == generation else { return }
                fire(queryItems: queryItems, channels: channels.dropFirst(), generation: gen,
                     verify: verify, sawAnswerWithoutStore: sawStale, completion: completion)
            }
        }
        guard let channel = channels.first else { giveUp(); return }
        guard var comps = URLComponents(string: channel.setEndpoint) else { giveUp(); return }
        comps.queryItems = queryItems
        guard let url = comps.url else { giveUp(); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = attemptTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session.dataTask(with: request) { data, response, error in
            guard SpoofDoctor.interpretProbe(data: data, response: response, error: error) else {
                next(sawStale: sawAnswerWithoutStore)
                return
            }
            guard let verify else {
                rememberChannel(channel)
                q.async { completion(.landed) }
                return
            }
            verify(channel) { stored in
                if stored {
                    rememberChannel(channel)
                    q.async { completion(.landed) }
                } else {
                    // Answered, but the store didn't take it: a stale control script. Don't pin to this
                    // channel — try the other one, and remember WHY if both fail, so the UI can say
                    // "re-import your config" instead of "the proxy is off".
                    next(sawStale: true)
                }
            }
        }.resume()
    }
}
