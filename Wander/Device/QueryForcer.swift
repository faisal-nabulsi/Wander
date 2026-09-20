//
//  QueryForcer.swift
//  Wander
//
//  THE MOVEMENT EXPERIMENT — demand-side WPS query forcing.
//
//  gs-loc can only move the fix when locationd issues a fresh WPS lookup we can rewrite. When the phone
//  is stationary, locationd serves from its ~400-AP cache and issues no lookup, which is WHY gs-loc has
//  been assumed teleport-only. But "how often does locationd re-query" was never measured, and "can an
//  app FORCE a re-query" was never tried — every prior lever was response-side (rewrite what Apple
//  sends). This is the demand side.
//
//  The mechanism: locationd is event-driven. This hammers it with the events an UNPRIVILEGED app can
//  generate and that plausibly trigger a re-localization — a one-shot high-accuracy request, and a
//  region-monitor register/teardown cycle (boundary evaluation forces locationd to re-fix). It does NOT
//  itself measure anything; the proxy (ProxyProbeServer) counts the WPS-host connections. Run the proxy
//  with this OFF for a few minutes, then ON, and compare the rate. If forcing raises it toward one query
//  every few seconds, stepwise gs-loc movement becomes possible for the first time.
//
//  Honest prior: this probably fails — locationd may satisfy a one-shot request from cache without any
//  network lookup, in which case forcing does nothing and teleport-only is confirmed by measurement
//  rather than assumption. Either outcome is worth having.
//

import Foundation
import CoreLocation

@MainActor
final class QueryForcer: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var running = false
    @Published private(set) var ticks = 0
    @Published private(set) var lastAction = ""

    private let manager = CLLocationManager()
    private var timer: Timer?
    /// Regions are re-registered under rotating identifiers so each is genuinely new to locationd.
    private var regionSeq = 0

    /// How hard to push. 3s is below PoGo's ~5s sample interval, so if forcing works at this rate the
    /// fix would refresh fast enough to read as walking.
    private let interval: TimeInterval = 3.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    }

    func start() {
        stop()
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()   // a continuous demand floor
        running = true
        ticks = 0
        // Timer instead of a tight loop so the main actor stays responsive; each fire is one forcing round.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.forceOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastAction = "started — forcing every \(Int(interval))s"
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
        // Tear down any region we left registered so we don't leak monitors across runs.
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        running = false
    }

    /// One forcing round: a fresh one-shot request PLUS a rotate of a monitored region. Both are
    /// documented locationd re-localization triggers that need no special entitlement.
    private func forceOnce() {
        ticks += 1

        // (1) One-shot high-accuracy request. If locationd honours it with a network lookup rather than
        //     cache, this is a query.
        manager.requestLocation()

        // (2) Region churn. Registering a new circular region makes locationd establish where the
        //     boundary is relative to the device — a re-fix. We register around the current fix, then
        //     drop the previous one so at most one is ever live.
        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
           let here = manager.location?.coordinate {
            for old in manager.monitoredRegions { manager.stopMonitoring(for: old) }
            regionSeq += 1
            let region = CLCircularRegion(center: here, radius: 100, identifier: "wander.force.\(regionSeq)")
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }

        lastAction = "tick \(ticks): requestLocation + region rotate"
    }

    // Delegate stubs — we don't consume the fixes, we only want the demand to reach locationd.
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
