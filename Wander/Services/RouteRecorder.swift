//
//  RouteRecorder.swift
//  Wander
//
//  Captures the device's REAL GPS track (lat/lng + timestamp per fix) into a named
//  route so it can be replayed later at its real pace — the "record a believable
//  commute, replay it while you're elsewhere" (Life360) use case.
//
//  IMPORTANT: this records the REAL location provider, never the spoofed one. While a
//  simulation/spoof is active the OS location IS the spoof, so the UI must DISABLE
//  recording (see RouteModeView). This recorder does not itself simulate anything.
//

import Foundation
import CoreLocation

/// A single captured real-GPS fix: where and when.
struct RecordedFix {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
}

/// Records real device GPS with standard continuous CoreLocation updates. Owns its own
/// CLLocationManager (distinct from CurrentLocation's one-shot manager) so it can stream
/// fixes for the duration of a recording.
@MainActor
final class RouteRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// Whether a recording is currently in progress.
    @Published private(set) var isRecording = false
    /// Number of fixes captured so far in the active recording (for live UI).
    @Published private(set) var fixCount = 0
    /// Total distance of the captured track in meters (for live UI).
    @Published private(set) var distanceMeters: CLLocationDistance = 0
    /// Wall-clock time the current recording started, for an elapsed-time readout.
    @Published private(set) var startedAt: Date?

    private let manager = CLLocationManager()
    private var fixes: [RecordedFix] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        // Every meaningful move should land a point; the OS still coalesces bad fixes.
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Ask for permission if we don't have it yet. Safe to call repeatedly.
    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Begin capturing real GPS. No-op if already recording. Caller is responsible for
    /// ensuring no spoof is active (recording the real provider only makes sense then).
    func start() {
        guard !isRecording else { return }
        fixes.removeAll()
        fixCount = 0
        distanceMeters = 0
        startedAt = Date()
        isRecording = true
        manager.startUpdatingLocation()
    }

    /// Stop capturing and return the recorded fixes (empty if nothing usable was captured).
    @discardableResult
    func stop() -> [RecordedFix] {
        guard isRecording else { return fixes }
        manager.stopUpdatingLocation()
        isRecording = false
        startedAt = nil
        return fixes
    }

    /// Discard the active/last recording without saving.
    func cancel() {
        if isRecording { manager.stopUpdatingLocation() }
        isRecording = false
        startedAt = nil
        fixes.removeAll()
        fixCount = 0
        distanceMeters = 0
    }

    /// Coordinates captured so far, in order.
    var coordinates: [CLLocationCoordinate2D] { fixes.map(\.coordinate) }
    /// Capture times (unixtime seconds) parallel to `coordinates`.
    var timestamps: [Double] { fixes.map { $0.timestamp.timeIntervalSince1970 } }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Snapshot on the shared actor since we mutate published state.
        let snapshot = locations
        Task { @MainActor in
            guard self.isRecording else { return }
            for loc in snapshot {
                // Drop obviously bad fixes: invalid coords or wildly inaccurate readings.
                guard CLLocationCoordinate2DIsValid(loc.coordinate),
                      loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { continue }
                if let last = self.fixes.last {
                    let prev = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                    self.distanceMeters += prev.distance(from: loc)
                }
                self.fixes.append(RecordedFix(coordinate: loc.coordinate, timestamp: loc.timestamp))
                self.fixCount = self.fixes.count
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}

/// Build playback samples from a recorded route, preserving the REAL captured timing
/// (the delay between consecutive samples is the actual gap between the two GPS fixes).
/// Falls back to a modest fixed cadence for any pair whose timestamps are missing,
/// non-increasing, or absurdly long (a pause/GPS gap), so replay never stalls.
/// Returns `[]` if there aren't at least two usable coordinates.
func buildRecordedPlaybackSamples(
    coordinates: [CLLocationCoordinate2D],
    timestamps: [Double]
) -> [RoutePlaybackSample] {
    guard coordinates.count >= 2, coordinates.count == timestamps.count else { return [] }

    var samples = [RoutePlaybackSample(coordinate: coordinates[0], delayFromPrevious: 0)]
    for i in 1..<coordinates.count {
        let dt = timestamps[i] - timestamps[i - 1]
        // Clamp: never negative, and cap a long stationary gap so a replay doesn't sit
        // frozen for minutes. A reasonable upper bound keeps pacing believable.
        let delay = min(max(dt, 0), 30)
        samples.append(RoutePlaybackSample(coordinate: coordinates[i], delayFromPrevious: delay))
    }
    return samples
}
