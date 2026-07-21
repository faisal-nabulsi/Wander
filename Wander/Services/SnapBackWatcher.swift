//
//  SnapBackWatcher.swift
//  Wander
//
//  Gentle SNAP-BACK detection for reboot-aware recovery.
//
//  While spoofing, iOS 26 sometimes pulls the device's reported location back toward where it
//  REALLY is (Wi-Fi/cell correction, a dropped tunnel, a background suspension). When that happens
//  the spoof has effectively "bounced back": the device's real reported location no longer sits near
//  the spoofed target. This watcher detects that condition and flips `didBounceBack` so the UI can
//  offer a gentle recovery — a one-tap re-teleport, plus a community-reported (NOT guaranteed)
//  reboot suggestion.
//
//  It ONLY signals after an ACTUAL detected bounce-back — never proactively. It reads the device's
//  REAL location via CLLocationManager (the same read CurrentLocation uses) and compares it to the
//  session's last teleport target. It does not inject anything and never blocks spoofing.
//

import Foundation
import CoreLocation

@MainActor
final class SnapBackWatcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Set to `true` once a real bounce-back is detected while spoofing (device's real reported
    /// location has drifted far from the spoofed target). The UI shows the recovery prompt off this;
    /// resetting it (resume / dismiss) is done via `reset()`.
    @Published private(set) var didBounceBack = false

    /// The target we're currently guarding — the last confirmed teleport coordinate.
    private var guardedTarget: CLLocationCoordinate2D?

    /// When the current guard was armed. We ignore fixes within a short settle window so a stale
    /// cached fix delivered the instant after teleport can't be mistaken for a bounce-back.
    private var armedAt = Date.distantPast

    /// Consecutive far-from-target fixes seen. We require two in a row before signalling so a single
    /// stray/stale reading never fires the prompt.
    private var consecutiveFar = 0

    private let manager = CLLocationManager()

    /// Ignore fixes for this long after arming (lets the injected fix become the reported one).
    private let settleWindow: TimeInterval = 4

    /// How far the device's REAL reported location must be from the spoofed target before we call it
    /// a bounce-back. Conservative on purpose — a large teleport that hasn't bounced still reports the
    /// injected (target) location, so a genuine bounce-back reads as hundreds+ of metres of drift back
    /// toward the real position. Kept well above normal breathing-jitter / GPS noise.
    private let bounceBackThresholdMeters: CLLocationDistance = 500

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Begin watching for a bounce-back away from `target`. Called when a spoof session starts /
    /// re-teleports. No-ops (and stops watching) if location isn't authorized — we simply can't read
    /// the real fix then, so we never surface a false prompt.
    func start(guarding target: CLLocationCoordinate2D) {
        guardedTarget = target
        didBounceBack = false
        armedAt = Date()
        consecutiveFar = 0
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startMonitoringSignificantLocationChanges()
            manager.startUpdatingLocation()
        default:
            // Not authorized — can't read the real fix, so we can't detect a bounce-back. Stay quiet.
            break
        }
    }

    /// Stop watching (session stopped, or the prompt was handled).
    func stop() {
        guardedTarget = nil
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
    }

    /// Clear the signal without stopping (e.g. after the user taps Resume, before we re-arm on the
    /// fresh teleport, or after they dismiss the prompt for the current target).
    func reset() {
        didBounceBack = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let real = locations.last?.coordinate else { return }
        Task { @MainActor in self.evaluate(realLocation: real) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }

    private func evaluate(realLocation: CLLocationCoordinate2D) {
        guard let target = guardedTarget, !didBounceBack else { return }
        // With Precise Location OFF, iOS reports a reduced-accuracy fix fuzzed by a stable per-app
        // offset that can sit hundreds of metres to >1 km from the true point — well past our 500 m
        // bounce-back threshold — so it would false-fire. We can't tell that fuzz from a real
        // bounce-back, so we simply don't guard when accuracy is reduced. Stay quiet.
        guard manager.accuracyAuthorization != .reducedAccuracy else { return }
        // Settle window: ignore fixes right after arming so a stale cached fix can't false-trigger.
        guard Date().timeIntervalSince(armedAt) >= settleWindow else { return }
        let real = CLLocation(latitude: realLocation.latitude, longitude: realLocation.longitude)
        let spoofed = CLLocation(latitude: target.latitude, longitude: target.longitude)
        // A HEALTHY spoof reports the injected target back through Core Location, so the real read
        // sits ~on the target. A bounce-back is the real position drifting far from it. Require two
        // consecutive far fixes so a single stray reading never fires the prompt.
        if real.distance(from: spoofed) >= bounceBackThresholdMeters {
            consecutiveFar += 1
            if consecutiveFar >= 2 {
                didBounceBack = true
            }
        } else {
            consecutiveFar = 0
        }
    }
}
