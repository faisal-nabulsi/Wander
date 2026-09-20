//
//  TunnelHealthMonitor.swift
//  Wander
//
//  A persistent heartbeat for the on-device tunnel/DDI connection — the layer Wander injects
//  location through. This addresses the #1 support symptom: the tunnel dropping mid-session and the
//  location "snapping back" to real GPS.
//
//  It classifies health as:
//    • green    (connected)    — a CONFIRMED recent inject (the probe cannot veto this — see below)
//    • yellow   (unstable)     — reachable but unproven: one failure, an unlanded write, or nothing
//                                confirmed in the last 20 s
//    • red      (disconnected) — repeated inject failures, or nothing confirmed AND unreachable
//
//  The signal is derived from TWO honest sources, never a fabricated one:
//    1. `TunnelInjectStatus` — the real success/failure of every `simulate_location` call (fed from
//       the FFI bridge, so it sees every inject regardless of which mode drove it).
//    2. A LIGHT reachability poll (`isTunnelSimEndpointReachable`, a bounded TCP probe to ip:49152)
//       that runs ONLY while a simulation is active — never in a tight loop, never while idle.
//
//  ⚠️ THOSE TWO DISAGREE ON CELLULAR, BY DESIGN, AND (1) WINS. The probe opens a NEW connection, and
//  new connections to the pairing listener are refused on mobile data no matter how healthy the
//  session is; an ESTABLISHED session keeps working straight through it. Ordering the probe first is
//  what made a working cellular spoof sit on a red chip and get "reconnected" six times. See
//  `apply(snapshot:reachable:)` for the full reasoning and for why a SOFT success may not count.
//
//  On drop it makes a BEST-EFFORT auto-reconnect by re-asserting the last teleport target through
//  the EXISTING teleport path (SimulationSession.resume → `.teleportToRequested`), with a small
//  backoff and a hard attempt cap — and only from RED, never from yellow, and never on cellular
//  where a rebuild is refused by the platform and the honest answer is Cellular Mode. This is honest
//  recovery, NOT a guarantee: iOS can background-terminate the app/tunnel and there is no way to
//  prevent that. Copy stays "trying to reconnect…", never "fixed".
//

import Foundation
import UIKit

@MainActor
final class TunnelHealthMonitor: ObservableObject {
    static let shared = TunnelHealthMonitor()

    enum State: Equatable {
        case connected    // green
        case unstable     // yellow
        case disconnected // red

        var isHealthy: Bool { self == .connected }
    }

    /// Current classified health. Drives the persistent chip. Starts `.connected` so a fresh, healthy
    /// session never flashes red before the first poll lands.
    @Published private(set) var state: State = .connected

    /// True while a best-effort auto-reconnect is in flight (chip shows "trying to reconnect…").
    @Published private(set) var isReconnecting = false

    /// Raised when iOS delivers a memory warning while spoofing. A dropped tunnel under memory
    /// pressure is a real failure mode (iOS reclaims the network extension), so we surface a
    /// non-blocking "close background apps" nudge. Cleared after a short while or on dismiss.
    @Published private(set) var memoryPressureWarning = false

    // MARK: - Tunables (verify-first)
    //
    // Poll cadence is intentionally conservative and only runs WHILE ACTIVE. These are safe starting
    // values; the exact interval is pending on-device battery testing — tune here, not at call sites.

    /// How often to run the light reachability probe while a simulation is active.
    private let pollInterval: TimeInterval = 4
    /// A success is considered "recent" (green) for this long after the last confirmed inject.
    private let recentSuccessWindow: TimeInterval = 20
    /// Consecutive inject failures at/above this count → red (disconnected).
    private let downFailureThreshold = 2
    /// How long the transient memory-pressure banner stays up before auto-clearing.
    private let memoryWarningDuration: TimeInterval = 12

    // MARK: - Auto-reconnect backoff
    private let maxReconnectAttempts = 6
    /// Spacing between reconnect attempts (grows a little each try). Best-effort only.
    // Extended past the airplane-off window: turning Airplane Mode OFF re-attaches cellular, and iOS
    // lockdownd refuses NEW connections for a while during that transition (so a rebuild keeps failing
    // until it settles). The old 3-attempt / ~17 s budget quit before the tunnel came back, leaving the
    // spoof reset until a manual re-teleport. ~72 s of attempts outlasts a typical re-attach; on success
    // setState(.connected) resets the counter, and attemptReconnectNow() refreshes it on foreground/snap-back.
    private let reconnectBackoff: [TimeInterval] = [2, 5, 10, 15, 20, 20]
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?

    private var pollTimer: Timer?
    private var memoryClearWork: DispatchWorkItem?
    private var memoryObserver: NSObjectProtocol?
    private var isActive = false

    private init() {
        // Observe iOS memory warnings for the whole app lifetime. A warning only surfaces UI while a
        // simulation is active (a dropped tunnel only matters then), but registering once is cheapest.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryWarning() }
        }
    }

    // MARK: - Lifecycle (driven by SimulationSession.isActive)

    /// Begin monitoring — called when a spoof session starts. Clears stale inject history so a failure
    /// from a previous run can't paint the chip red the instant a fresh, healthy session begins.
    func startMonitoring() {
        guard !isActive else { return }
        isActive = true
        reconnectAttempt = 0
        isReconnecting = false
        // FAILURES ONLY. A full `reset()` here also erased the CONFIRMED SUCCESS that the teleport
        // calling us had just recorded — see `TunnelInjectStatus.resetFailures`. That is the one piece
        // of evidence allowed to outrank a reachability probe, and on mobile data the probe can never
        // say yes, so wiping it here is what refused a Cellular Mode drive on the session Cellular
        // Mode had just built.
        TunnelInjectStatus.resetFailures()
        state = .connected
        startPolling()
    }

    /// Stop monitoring — called on any Stop/clear. Cancels the poll + any pending reconnect and resets
    /// to a neutral healthy state so the chip disappears cleanly.
    func stopMonitoring() {
        isActive = false
        pollTimer?.invalidate()
        pollTimer = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempt = 0
        isReconnecting = false
        state = .connected
        clearMemoryWarning()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // Evaluate once immediately so the chip reflects reality without waiting a full interval,
        // then on the light cadence. `.common` mode so map/scroll interaction doesn't stall it.
        evaluate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Classification

    /// Classify health from the real inject history + one light reachability probe. Runs off the main
    /// thread for the (bounded) socket probe, then publishes back on main. Never blocks the UI.
    private func evaluate() {
        guard isActive else { return }
        // In PoGo (gs-loc) mode Wander drives the Shadowrocket proxy, NOT Apple's dev tunnel —
        // LocalDevVPN is intentionally OFF (iOS allows only one VPN at a time). Don't probe the dev
        // endpoint (it would false-red and spam reconnects). Instead drive the chip HONESTLY from the
        // proxy's presence: green when a proxy VPN is active, red when it's off — never a fake green
        // that hides a misconfigured proxy whose location never moves.
        if GslocMode.enabled {
            setState(Self.isProxyActive() ? .connected : .disconnected)
            return
        }
        let snap = TunnelInjectStatus.snapshot
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Only probe reachability while active; the probe itself is bounded (poll timeout).
            let reachable = isTunnelSimEndpointReachable()
            Task { @MainActor in self.apply(snapshot: snap, reachable: reachable) }
        }
    }

    /// ══ A CONFIRMED INJECT OUTRANKS THE REACHABILITY PROBE. READ THIS BEFORE REORDERING IT. ══
    ///
    /// The two inputs do not measure the same thing, and on cellular they disagree BY DESIGN:
    ///
    ///   • `reachable` is a NEW TCP connect to `liveTarget:49152`. `remotepairingdeviced` applies
    ///     `SO_RESTRICT_DENY_CELLULAR` to its own listeners, and XNU's `in_pcblookup_hash_locked()`
    ///     SKIPS a restricted socket rather than refusing it — so the connect takes the no-such-port
    ///     path and gets an instant RST. Our own tunnel utun measures `IFRTYPE_FUNCTIONAL_CELLULAR`,
    ///     so this happens even over the tunnel. On mobile data this probe therefore returns FALSE
    ///     for a perfectly healthy session, every single time.
    ///   • `lastSuccessAt` is the real return code of a real `location_simulation_set` on the
    ///     ESTABLISHED handle. The wall is on tunnel BIRTH only; an established session keeps working.
    ///
    /// This used to test `!reachable` FIRST, which meant successful injects could never clear it: on
    /// the flagship cellular flow the chip went red and STAYED red on a working spoof, and `setState`
    /// then fired up to six auto-reconnects — each one yanking the user to the Location tab,
    /// re-teleporting, and charging a free-trial teleport — to "fix" a session that was fine.
    ///
    /// So the order is inverted, and it is not a fabricated green: the device confirming a coordinate
    /// is strictly better evidence of a live session than our ability to open a second connection to
    /// it. The one thing that must not happen is treating a SOFT success as that evidence — a write
    /// still in flight, or one that timed out and was deliberately kept, both report `ok` without
    /// having landed. Those fall through to "unstable", which is the honest word for "we don't know".
    private func apply(snapshot snap: TunnelInjectStatus.Snapshot, reachable: Bool) {
        guard isActive else { return }
        let now = Date()
        let recentSuccess = snap.lastSuccessAt.map { now.timeIntervalSince($0) <= recentSuccessWindow } ?? false
        let recentConfirmedSuccess = recentSuccess && !snap.lastSuccessWasSoft

        let newState: State
        if snap.consecutiveFailures >= downFailureThreshold {
            // Repeated real inject failures. This is the device telling us, not us guessing.
            newState = .disconnected
        } else if recentConfirmedSuccess && snap.consecutiveFailures == 0 {
            // The device took a coordinate within the window. Whatever the probe says about opening a
            // NEW connection, the one we have is carrying traffic.
            newState = .connected
        } else if !reachable {
            // No confirmed inject to lean on AND we can't open a connection. Now it really is down.
            newState = .disconnected
        } else {
            // Reachable but shaky: an intermittent failure, a soft (unlanded) write, or nothing
            // confirmed in a while.
            newState = .unstable
        }

        setState(newState)
    }

    /// Best-effort "is a proxy VPN (e.g. Shadowrocket) active?" — the gs-loc path's health signal.
    /// Synchronous and cheap (no network). Shadowrocket installs a scoped system proxy while connected.
    private static func isProxyActive() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        return settings.keys.contains { $0.hasPrefix("HTTP") || $0.hasPrefix("SOCKS") || $0 == "__SCOPED__" }
    }

    private func setState(_ newState: State) {
        // On the TRANSITION into red only — never on every poll — snapshot the interface list. A tunnel
        // that just went unreachable is exactly when the "which interfaces does this phone have" question
        // has to be answered, and it can't be answered after the fact. Throttled inside the dump.
        if newState == .disconnected, state != .disconnected, !GslocMode.enabled {
            NetworkInterfaceDump.logOnFailure(reason: "tunnel health went red")
        }
        if newState != state { state = newState }
        // Kick a best-effort reconnect when unhealthy; back off to healthy resets the attempt counter.
        switch newState {
        case .connected:
            if reconnectAttempt != 0 || isReconnecting {
                reconnectAttempt = 0
                isReconnecting = false
                reconnectWork?.cancel()
                reconnectWork = nil
            }
        case .unstable:
            // NO AUTO-RECONNECT FROM YELLOW (changed here). "Unstable" means reachable-but-unproven:
            // one intermittent failure, a write still in flight, or simply no confirmed inject in the
            // last 20 s. The hold loop produces another inject every 4 s, so this self-heals — and a
            // reconnect is not a quiet retry, it yanks the user to the Location tab, re-teleports and
            // charges a trial teleport. Paying that for a condition that clears itself is what made a
            // working session feel broken. Red still recovers; yellow waits one more tick.
            break
        case .disconnected:
            scheduleReconnectIfNeeded()
        }
    }

    // MARK: - Best-effort auto-reconnect
    //
    // Re-asserts the last teleport target through the EXISTING teleport path (never a bespoke DDI
    // remount): SimulationSession.resume posts `.teleportToRequested`, which the Map screen handles by
    // re-selecting the coordinate and calling simulate() (that re-mounts the tunnel through the normal
    // flow). Capped + backed off. Best-effort only — we can't stop iOS from killing the extension.

    /// Called externally too (e.g. on the opp-5 snap-back bounce signal) to try a reconnect now.
    func attemptReconnectNow() {
        guard isActive else { return }
        // A fresh external kick (foreground return, or a snap-back the watcher detected) refreshes the
        // retry budget, so a reconnect run that exhausted its attempts while we were backgrounded doesn't
        // stay permanently given-up — the user coming back to the app restarts persistent recovery.
        reconnectAttempt = 0
        scheduleReconnectIfNeeded(force: true)
    }

    private func scheduleReconnectIfNeeded(force: Bool = false) {
        guard isActive else { return }
        // gs-loc mode has no dev tunnel to reconnect — the proxy is the user's to manage. Re-asserting
        // the teleport here would just re-push to the proxy pointlessly (and a red chip in gs-loc mode
        // means "proxy down", which we can't fix from here).
        guard !GslocMode.enabled else { return }
        // Only auto-reconnect the Map teleport HOLD. When a movement mode (Walk/Route/Itinerary) is the
        // active writer it holds suppressResends=true and self-heals via its own inject loop when the
        // tunnel returns — re-asserting the Map resend here would add a SECOND writer to the serial queue
        // AND re-inject the stale pre-walk `lastTeleportCoordinate` (a backward jump), regressing the
        // Error-12 single-writer fix. So skip the reconnect while another mode owns the stream.
        guard !LocationSimulationCommandQueue.suppressResends else { return }
        // ── ON CELLULAR THERE IS NOTHING TO RETRY, SO WE DON'T PRETEND ──────────────────────────
        //
        // A rebuild has to open a NEW connection to the pairing listener, and on mobile data with no
        // Wi-Fi that connection is refused by construction (`SO_RESTRICT_DENY_CELLULAR` on the
        // listener; the socket is skipped by the port lookup, so it is an instant RST, not a slow
        // failure we could outwait). No entitlement, address, or backoff reaches it. Six attempts
        // over ~72 s therefore buy exactly nothing here — while costing six forced tab switches, six
        // re-teleports, and up to six modal alerts carrying advice that cannot work.
        //
        // The recovery on cellular is an Airplane Mode cycle, which only the user can perform. So we
        // report the loss ONCE and offer Cellular Mode, instead of thrashing. `SpoofLossReporter`
        // de-duplicates, so calling this on every 4 s poll costs one report per death.
        //
        // THIS ALSO CATCHES THE USER'S OWN "Try to reconnect" TAP, on purpose. Answering that tap with
        // a retry we know is refused would be the app performing effort it knows is futile; answering
        // it with the Cellular Mode offer hands them the thing that actually works. The transport is
        // re-read at the moment of the tap, so a user who has since joined Wi-Fi takes the normal path.
        if NetworkReachability.isOnCellularSnapshot {
            // ⚠️ ONLY CLAIM A LOSS WHEN NO HANDLE IS OPEN. Red on cellular is not by itself proof the
            // session died: a write still in flight reports a SOFT success, which is not confirmation,
            // and the probe is refused on cellular no matter how healthy we are — so "unreachable and
            // unconfirmed" describes an ordinary stall just as well as a death. Stalls are common in
            // the exact window that matters (turning Airplane Mode back off), and a "your spoof
            // stopped" notification fired at somebody whose spoof is fine would make this feature
            // worse than the silence it replaces. `isSessionHeld` is a fact, not an inference.
            if !LocationSessionProbeState.isSessionHeld {
                // No handle, so recovery means a REBUILD, and a rebuild needs a new connection that
                // this platform refuses on cellular. Report once; the answer is Cellular Mode.
                SpoofLossReporter.shared.noteSessionLost(
                    LocationSessionProbeState.lastTeardownReason ?? "tunnel unreachable on cellular")
                isReconnecting = false
                return
            }
            // The handle IS still open. A re-assert here writes through the CACHED handle and never
            // opens a connection, so it is not blocked by the cellular wall and is a real thing to
            // try — but only when a person asked for it. Letting the 4 s poll drive it would put the
            // user through up to six forced tab switches and six charged trial teleports during a
            // stall that resolves itself, which is the storm this whole change exists to end.
            guard force else {
                isReconnecting = false
                return
            }
        }
        guard reconnectWork == nil else { return } // one in flight already
        guard force || reconnectAttempt < maxReconnectAttempts else {
            // Out of attempts: stop claiming we're reconnecting. Leaving this true is what made the chip
            // sit on "reconnecting…" forever even though nothing was being retried any more.
            isReconnecting = false
            return
        }
        guard let target = SimulationSession.shared.lastTeleportCoordinate else { return }

        let delay = reconnectBackoff[min(reconnectAttempt, reconnectBackoff.count - 1)]
        isReconnecting = true
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.reconnectWork = nil
                self.reconnectAttempt += 1
                LogManager.shared.addInfoLog(
                    "Tunnel health: best-effort reconnect attempt \(self.reconnectAttempt) → re-asserting last target"
                )
                // Revive the TUNNEL first, then re-assert. Re-asserting a teleport is pointless if the
                // VPN carrying it is down — and nothing else in the app ever restarted it, so a dropped
                // tunnel used to leave a silently dead session until the user noticed. No-ops unless the
                // user opted into Wander's own tunnel, and never while gs-loc owns the VPN slot.
                await WanderTunnel.shared.ensureStarted()
                // Reuse the normal teleport path (re-mounts the tunnel). Does NOT guarantee recovery.
                SimulationSession.shared.resume(to: target)
                // If the next poll shows health recovered, setState() clears isReconnecting. If not and
                // we're still under the cap, another attempt is scheduled by the next evaluate().
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Memory pressure

    private func handleMemoryWarning() {
        LogManager.shared.addInfoLog("Received iOS memory warning")
        // Only nag while spoofing — a dropped tunnel only matters then.
        guard isActive else { return }
        memoryPressureWarning = true
        memoryClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.memoryPressureWarning = false }
        }
        memoryClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + memoryWarningDuration, execute: work)
    }

    func clearMemoryWarning() {
        memoryClearWork?.cancel()
        memoryClearWork = nil
        memoryPressureWarning = false
    }
}
