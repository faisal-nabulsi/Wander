//
//  TunnelHealthMonitor.swift
//  Wander
//
//  A persistent heartbeat for the on-device tunnel/DDI connection — the layer Wander injects
//  location through. This addresses the #1 support symptom: the tunnel dropping mid-session and the
//  location "snapping back" to real GPS.
//
//  It classifies health as:
//    • green    (connected)    — a recent successful inject AND the sim endpoint is reachable
//    • yellow   (unstable)     — intermittent inject failures, OR reachable but no recent success
//    • red      (disconnected) — endpoint unreachable, or repeated inject failures
//
//  The signal is derived from TWO honest sources, never a fabricated one:
//    1. `TunnelInjectStatus` — the real success/failure of every `simulate_location` call (fed from
//       the FFI bridge, so it sees every inject regardless of which mode drove it).
//    2. A LIGHT reachability poll (`isTunnelSimEndpointReachable`, a bounded TCP probe to ip:49152)
//       that runs ONLY while a simulation is active — never in a tight loop, never while idle.
//
//  On drop it makes a BEST-EFFORT auto-reconnect by re-asserting the last teleport target through
//  the EXISTING teleport path (SimulationSession.resume → `.teleportToRequested`), with a small
//  backoff and a hard attempt cap. This is honest recovery, NOT a guarantee: iOS can background-
//  terminate the app/tunnel and there is no way to prevent that. Copy stays "trying to reconnect…",
//  never "fixed".
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
    private let maxReconnectAttempts = 3
    /// Spacing between reconnect attempts (grows a little each try). Best-effort only.
    private let reconnectBackoff: [TimeInterval] = [2, 5, 10]
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
        TunnelInjectStatus.reset()
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
        let snap = TunnelInjectStatus.snapshot
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Only probe reachability while active; the probe itself is bounded (poll timeout).
            let reachable = isTunnelSimEndpointReachable()
            Task { @MainActor in self.apply(snapshot: snap, reachable: reachable) }
        }
    }

    private func apply(snapshot snap: TunnelInjectStatus.Snapshot, reachable: Bool) {
        guard isActive else { return }
        let now = Date()
        let recentSuccess = snap.lastSuccessAt.map { now.timeIntervalSince($0) <= recentSuccessWindow } ?? false

        let newState: State
        if !reachable || snap.consecutiveFailures >= downFailureThreshold {
            // Endpoint gone or repeated inject failures → the tunnel is effectively down.
            newState = .disconnected
        } else if snap.consecutiveFailures > 0 || !recentSuccess {
            // Reachable but shaky: an intermittent failure, or no confirmed inject in a while.
            newState = .unstable
        } else {
            newState = .connected
        }

        setState(newState)
    }

    private func setState(_ newState: State) {
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
        case .unstable, .disconnected:
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
        scheduleReconnectIfNeeded(force: true)
    }

    private func scheduleReconnectIfNeeded(force: Bool = false) {
        guard isActive else { return }
        guard reconnectWork == nil else { return } // one in flight already
        guard force || reconnectAttempt < maxReconnectAttempts else { return }
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
