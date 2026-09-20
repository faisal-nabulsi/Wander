//
//  BackgroundLocationManager.swift
//  Wander
//

import CoreLocation

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false

    /// Per-view leases (Walk, Route, the JIT debug lease, the link-automation hold). Each of those
    /// callers guards itself with its own `keepAliveHeld` latch, so this count is balanced BY THEM.
    private var activityCount = 0

    /// THE SPOOF SESSION'S OWN LEASE, and deliberately NOT part of `activityCount`.
    ///
    /// It used to be. `SimulationSession.started()` called `requestStart()` and `started()` has
    /// thirteen call sites (every teleport, not every session), while `stopAll()` released once and
    /// `markStopped()` — which is what the Map tab's Stop actually uses — released not at all. So the
    /// count only ever went up: after one teleport-and-stop cycle it sat at ≥1 for the rest of the
    /// process, continuous 100 m updates ran forever, and `requestStop()` was effectively dead code.
    /// The direction of that bug matters: it made background SURVIVAL better and battery worse, so
    /// "just balance the calls" would have made sessions die MORE often. Hence a lease instead of a
    /// count — the session either has one or it does not, thirteen `started()` calls take the same
    /// single lease, and either stop path releases it.
    ///
    /// It is separate from the count so that an unmatched `requestStop()` elsewhere (there is one, on
    /// MainTabView's URL-driven clear) can never release a live session's keep-alive.
    private var sessionLeaseHeld = false

    /// The keep-alive runs while EITHER the spoof session holds its lease or some view holds a count.
    private var shouldRun: Bool { sessionLeaseHeld || activityCount > 0 }

    private override init() {
        super.init()
        locationManager.delegate = self
        // These settings ARE the keep-alive, not a preference.
        //
        // The `location` background mode grants no runtime just by being declared — iOS keeps the app
        // alive only while updates are ACTIVELY BEING DELIVERED, and Apple's bar is
        // kCLLocationAccuracyHundredMeters or better with no distance filter.
        //
        // This was kCLLocationAccuracyThreeKilometers with distanceFilter = CLLocationDistanceMax —
        // "only tell me if the device moves an effectively infinite distance" — so almost NO updates
        // were delivered. iOS saw nothing happening and let the app lapse, which is the ~2 minute blip
        // where a backgrounded route briefly snaps back: the lapse lets the system reclaim the socket
        // under the DVT connection (Apple TN2277), and the spoof only returns because the rebuild now
        // succeeds. Continuous updates remove the lapse, so there is nothing to recover from.
        //
        // Cost is battery. That is the deliberate trade for a spoof that survives backgrounding, and it
        // only runs while a simulation is active (activityCount) or the user opts in.
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        isRunning = true
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            // START THE UPDATES. This case used to only ask for Always and return, which meant a user
            // who had already granted When-In-Use and already declined Always got NO location
            // keep-alive at all — `requestAlwaysAuthorization()` produces no prompt and no
            // `locationManagerDidChangeAuthorization` callback once that decision is made, so nothing
            // ever started. They were riding on the silent-audio session alone and had no idea.
            //
            // When-In-Use is enough for the purpose: with `allowsBackgroundLocationUpdates = true`
            // and the `location` background mode declared, iOS keeps delivering updates after the app
            // leaves the foreground — it just shows the blue status-bar indicator, which is honest
            // (we ARE using location) and which Always would hide.
            locationManager.startUpdatingLocation()
            // Still worth asking, so an Always grant can later drop the blue bar. Harmless no-op once
            // the user has decided.
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func stop() {
        isRunning = false
        locationManager.stopUpdatingLocation()
    }

    /// Take/release the SPOOF SESSION's lease. Idempotent by design — see `sessionLeaseHeld`.
    func setSessionActive(_ active: Bool) {
        guard active != sessionLeaseHeld else { return }
        sessionLeaseHeld = active
        refresh()
    }

    func requestStart() {
        activityCount += 1
        refresh()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refresh()
    }

    /// The "Background Location" setting was toggled. Re-evaluates immediately so turning it back ON
    /// mid-session actually starts the keep-alive (it used to only take effect on the next lease).
    func settingDidChange() {
        refresh()
    }

    private func refresh() {
        let wanted = shouldRun && UserDefaults.standard.bool(forKey: "keepAliveLocation")
        guard wanted != isRunning else { return }
        if wanted { start() } else { stop() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location fixes may fail (e.g. no GPS indoors) — that's fine.
        // The manager just needs to be running, not actually fix a location.
    }
}
