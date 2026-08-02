//
//  BackgroundLocationManager.swift
//  Wander
//

import CoreLocation

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var activityCount = 0

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

    func requestStart() {
        activityCount += 1
        if activityCount == 1, UserDefaults.standard.bool(forKey: "keepAliveLocation") {
            start()
        }
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        if activityCount == 0 {
            stop()
        }
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
