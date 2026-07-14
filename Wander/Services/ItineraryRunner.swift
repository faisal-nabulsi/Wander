//
//  ItineraryRunner.swift
//  Wander
//
//  Executes an itinerary (see ItineraryQueue.swift) live, while Wander is open: it goes to
//  step 1 (teleport, or drive a realistic route to that spot), STAYS there for the step's
//  minutes, then advances to step 2, and so on. When the last step's stay elapses it stops.
//
//  HONEST LIMIT: this runs only while Wander is running (foreground / the app's existing
//  keep-alive). iOS can't fire a step when the app is fully closed — we do NOT fake
//  background scheduling; the UI tells the user to keep Wander open.
//
//  Teleport uses the same low-level path as MapSelectionView.simulate (simulate_location on
//  the shared command queue) and marks SimulationSession active so the global banner / Stop
//  and 2h reminder behave exactly like the other modes. Route steps drive a realistic,
//  road-following, ETA-paced track the same way RouteModeView does.
//

import Foundation
import CoreLocation
import MapKit

@MainActor
final class ItineraryRunner: ObservableObject {
    /// Whether the itinerary is currently running.
    @Published private(set) var isRunning = false
    /// Index of the step currently executing (nil when idle).
    @Published private(set) var activeIndex: Int?
    /// What the active step is doing right now.
    @Published private(set) var phase: Phase = .idle
    /// Seconds remaining in the current stay (0 while moving).
    @Published private(set) var stayRemaining: TimeInterval = 0

    enum Phase: Equatable {
        case idle
        case moving       // teleporting or driving to the step's location
        case staying      // parked at the location, counting down
        case finished
    }

    private var runTask: Task<Void, Never>?
    private var tickTimer: Timer?

    /// Resend cadence while parked at a teleport step, so the spoof survives iOS re-checks
    /// (mirrors MapSelectionView's 4s resend loop).
    private let resendInterval: TimeInterval = 4

    private var stopObserver: NSObjectProtocol?

    init() {
        // The always-available Panic button and any global stop broadcast .stopSimulationRequested.
        // The runner MUST honor it — otherwise its next resend/route tick would revive the spoof
        // the user just tried to kill.
        stopObserver = NotificationCenter.default.addObserver(
            forName: .stopSimulationRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    deinit {
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
    }

    // MARK: - Control

    /// Start running the given steps in order. No-op if already running or the list is empty,
    /// or if a pairing file isn't available.
    func start(steps: [ItineraryStep]) {
        guard !isRunning, !steps.isEmpty else { return }
        guard pairingFilePath() != nil else { return }

        isRunning = true
        phase = .moving
        SimulationSession.shared.started()

        runTask = Task { [weak self] in
            await self?.run(steps: steps)
        }
    }

    /// Stop the itinerary and clear the device location (global stop path, like every mode).
    /// Idempotent: stopAll() re-broadcasts .stopSimulationRequested, which re-enters here via
    /// the observer, so bail out once we're already torn down to avoid a loop.
    func stop() {
        guard isRunning || runTask != nil else { return }
        runTask?.cancel()
        runTask = nil
        stopTickTimer()
        isRunning = false
        activeIndex = nil
        phase = .idle
        stayRemaining = 0
        SimulationSession.shared.stopAll()
    }

    /// True only when a pairing file is present (needed to simulate at all).
    var canRun: Bool { pairingFilePath() != nil }

    // MARK: - Execution

    private func run(steps: [ItineraryStep]) async {
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { break }
            activeIndex = index
            phase = .moving
            stayRemaining = 0

            switch step.move {
            case .teleport:
                sendOnce(step.coordinate)
            case .route:
                await drive(to: step.coordinate)
            }
            if Task.isCancelled { break }

            // STAY at the location for the configured minutes, resending periodically so the
            // spoof holds, and counting the visible countdown down.
            await stay(at: step.coordinate, seconds: step.stayDuration)
            if Task.isCancelled { break }
        }

        if !Task.isCancelled {
            phase = .finished
            // Finished the last step: stop cleanly and CLEAR the device location (revert to
            // real GPS) so we never leave a silent spoof running with the banner off.
            stopTickTimer()
            isRunning = false
            activeIndex = nil
            SimulationSession.shared.stopAll()
        }
    }

    /// Park at `coordinate` for `seconds`, resending the location every `resendInterval` and
    /// updating `stayRemaining` once a second for the countdown.
    private func stay(at coordinate: CLLocationCoordinate2D, seconds: TimeInterval) async {
        phase = .staying
        stayRemaining = seconds

        let deadline = Date().addingTimeInterval(seconds)
        var lastResend = Date()
        // Keep it pinned across the whole stay.
        sendOnce(coordinate)

        while !Task.isCancelled {
            let now = Date()
            let remaining = deadline.timeIntervalSince(now)
            stayRemaining = max(remaining, 0)
            if remaining <= 0 { break }

            if now.timeIntervalSince(lastResend) >= resendInterval {
                sendOnce(coordinate)
                lastResend = now
            }
            // Sleep ~1s (or the remaining slice, whichever is shorter) for a smooth countdown.
            let slice = min(remaining, 1.0)
            try? await Task.sleep(nanoseconds: UInt64(max(slice, 0.05) * 1_000_000_000))
        }
        stayRemaining = 0
    }

    // MARK: - Movement

    /// Teleport: one location update on the shared command queue (same as MapSelectionView).
    private func sendOnce(_ coordinate: CLLocationCoordinate2D) {
        guard let path = pairingFilePath() else { return }
        let target = UserDefaults.standard.bool(forKey: "jitterEnabled")
            ? LocationJitter.apply(coordinate)
            : coordinate
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, target.latitude, target.longitude, path)
        }
    }

    /// Drive a realistic road route to `destination`, starting from the current location if
    /// known (else jump straight there). Plays back an ETA-paced, road-following track like
    /// RouteModeView. Cancellable at any point via the run task.
    private func drive(to destination: CLLocationCoordinate2D) async {
        // Origin: the last real user location if we have one; otherwise there's nothing to
        // drive FROM, so just teleport to the destination.
        guard let origin = CLLocationManager().location?.coordinate else {
            sendOnce(destination)
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile

        var coords: [CLLocationCoordinate2D] = []
        var expected: TimeInterval = 0
        if let response = try? await MKDirections(request: request).calculate(),
           let route = response.routes.first {
            coords = coordinates(from: route.polyline)
            expected = route.expectedTravelTime
        }

        guard coords.count > 1 else {
            // No drivable route (e.g. across an ocean) — just teleport.
            sendOnce(destination)
            return
        }

        let samples = buildRealisticSamples(coords, totalDuration: expected,
                                            fallbackSpeed: 13.4 /* ~48 km/h */)
        guard samples.count > 1 else {
            sendOnce(destination)
            return
        }

        for sample in samples {
            if Task.isCancelled { return }
            if sample.delayFromPrevious > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sample.delayFromPrevious * 1_000_000_000))
            }
            if Task.isCancelled { return }
            sendOnce(sample.coordinate)
        }
    }

    // MARK: - Route sampling (mirrors RouteModeView.buildRealisticSamples)

    private func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    private func buildRealisticSamples(_ coords: [CLLocationCoordinate2D],
                                       totalDuration: TimeInterval,
                                       fallbackSpeed: Double) -> [RoutePlaybackSample] {
        guard coords.count > 1 else { return [] }

        var segDist: [Double] = []
        var totalDist = 0.0
        for i in 0..<(coords.count - 1) {
            let d = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                .distance(from: CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude))
            segDist.append(d)
            totalDist += d
        }
        guard totalDist > 0 else { return [] }

        var weights: [Double] = []
        var weightedDist = 0.0
        for i in 0..<segDist.count {
            var w = 1.0
            if i + 2 < coords.count {
                let b1 = bearing(coords[i], coords[i + 1])
                let b2 = bearing(coords[i + 1], coords[i + 2])
                var turn = abs(b2 - b1)
                if turn > 180 { turn = 360 - turn }
                w = max(1.0 - min(turn / 120.0, 1.0) * 0.65, 0.35)
            }
            weights.append(w)
            weightedDist += segDist[i] / w
        }

        let target = totalDuration > 0 ? totalDuration : totalDist / max(fallbackSpeed, 1)
        let baseSpeed = weightedDist / max(target, 1)
        let tick = 0.5

        var samples = [RoutePlaybackSample(coordinate: coords[0], delayFromPrevious: 0)]
        for i in 0..<segDist.count {
            let localSpeed = max(baseSpeed * weights[i], 0.5)
            let segTime = segDist[i] / localSpeed
            let steps = max(1, Int(ceil(segTime / tick)))
            let stepDelay = segTime / Double(steps)
            for s in 1...steps {
                let f = Double(s) / Double(steps)
                let lat = coords[i].latitude + (coords[i + 1].latitude - coords[i].latitude) * f
                let lon = coords[i].longitude + (coords[i + 1].longitude - coords[i].longitude) * f
                samples.append(RoutePlaybackSample(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    delayFromPrevious: stepDelay
                ))
            }
        }
        return samples
    }

    private func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    // MARK: - Helpers

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }
}
