//
//  RouteModeView.swift
//  Wander
//
//  Drive/walk a set path: start + intermediate stops + end. The app follows
//  the real road route (MKDirections) between the waypoints and plays it back,
//  either at the road's speed limit (OpenStreetMap data) or a fixed manual speed.
//

import SwiftUI
import MapKit
import CoreLocation

private struct RouteWaypoint: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
}

private enum RouteSpeedMode: String, CaseIterable, Identifiable {
    case realistic
    case speedLimit
    case manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .realistic: return "Realistic"
        case .speedLimit: return "Speed limit"
        case .manual: return "Manual"
        }
    }
}

struct RouteModeView: View {
    @State private var waypoints: [RouteWaypoint] = []
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @StateObject private var currentLocation = CurrentLocation()
    @State private var visibleCenter: CLLocationCoordinate2D?
    @State private var currentPosition: CLLocationCoordinate2D?

    @State private var speedMode: RouteSpeedMode = .realistic
    @State private var manualSpeedMps: Double = 50_000.0 / 3_600.0   // default 50 km/h
    @State private var routeExpectedTime: TimeInterval = 0            // real-world ETA from MKDirections
    @AppStorage("useMph") private var useMph = false
    @AppStorage("jitterEnabled") private var jitterEnabled = false

    @State private var isPaused = false
    @State private var playbackRate: Double = 1.0
    @State private var progress: Double = 0
    @State private var remainingSeconds: TimeInterval = 0

    @State private var isComputing = false
    @State private var isDriving = false
    @State private var playbackTask: Task<Void, Never>?

    @State private var alertText: String?

    private var manualMetersPerSecond: Double { max(manualSpeedMps, 1) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                controls
            }
            .navigationTitle("Route")
            .alert("Route", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(alertText ?? "") }
            .onDisappear { localReset() }
            .onReceive(NotificationCenter.default.publisher(for: .stopSimulationRequested)) { _ in
                localReset()
            }
            .onAppear { currentLocation.request() }
            .onReceive(currentLocation.$coordinate.compactMap { $0 }) { c in
                if waypoints.isEmpty && !isDriving {
                    cameraPosition = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2500, longitudinalMeters: 2500))
                }
            }
        }
    }

    private var map: some View {
        Map(position: $cameraPosition) {
            ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, wp in
                Marker(waypointLabel(index), coordinate: wp.coordinate)
                    .tint(index == 0 ? .green : (index == waypoints.count - 1 ? .red : .orange))
            }
            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(.blue, lineWidth: 4)
            }
            if let currentPosition {
                Annotation("You", coordinate: currentPosition) {
                    ZStack {
                        Circle().fill(.blue.opacity(0.25)).frame(width: 34, height: 34)
                        Circle().fill(.blue).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .continuous) { context in
            visibleCenter = context.region.center
        }
        .overlay(alignment: .center) {
            if !isDriving { MapCrosshair() }
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        WanderCard {
        VStack(spacing: 12) {
            if isComputing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !isDriving {
                AddressSearchBar(placeholder: "Search to add a point") { coord, _ in
                    waypoints.append(RouteWaypoint(coordinate: coord))
                    routeCoordinates = []
                    if let region = region(fitting: waypoints.map(\.coordinate)) {
                        cameraPosition = .region(region)
                    }
                }
                HStack {
                    Button { addWaypoint() } label: {
                        Label("Add point (\(waypoints.count))", systemImage: Wander.Icon.add)
                    }
                    Spacer()
                    if !waypoints.isEmpty {
                        Button(role: .destructive) { clearAll() } label: {
                            Label("Clear", systemImage: Wander.Icon.clear)
                        }
                    }
                }
                .font(.subheadline)

                if !waypoints.isEmpty {
                    Text(waypointSummary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Speed", selection: $speedMode) {
                    ForEach(RouteSpeedMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if speedMode == .realistic {
                    Text(routeExpectedTime > 0
                         ? "Real-world time ≈ \(Int((routeExpectedTime / 60).rounded())) min — paced like an actual drive (slows for turns, varies speed)."
                         : "Follows the real road time. Tap Preview route to estimate it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        Text(speedMode == .manual ? "Speed" : "Fallback speed")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { SpeedFormat.fromMps(manualSpeedMps, useMph: useMph) },
                                set: { manualSpeedMps = SpeedFormat.toMps($0, useMph: useMph) }
                            ),
                            in: SpeedFormat.sliderRange(useMph: useMph),
                            step: 1
                        )
                        Text("\(Int(SpeedFormat.fromMps(manualSpeedMps, useMph: useMph))) \(SpeedFormat.unitLabel(useMph: useMph))")
                            .font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }

                HStack(spacing: 10) {
                    Button { Task { await computeRoute() } } label: {
                        Label("Preview", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(waypoints.count < 2 || isComputing)

                    Button { Task { await startDrive() } } label: {
                        Label("Drive", systemImage: Wander.Icon.play)
                            .font(.headline)
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Wander.brand)
                    .controlSize(.large)
                    .disabled(routeCoordinates.count < 2 || isComputing)
                }
            } else {
                HStack {
                    Text("\(Int(progress * 100))%").font(.caption.bold()).monospacedDigit()
                    ProgressView(value: progress)
                    if remainingSeconds > 0 {
                        Text("~\(Int((remainingSeconds / 60).rounded())) min left")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Picker("Rate", selection: $playbackRate) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Button { isPaused.toggle() } label: {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? Wander.Icon.play : Wander.Icon.pause)
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Button(role: .destructive) { stopDrive() } label: {
                        Label("Stop", systemImage: Wander.Icon.stop)
                            .font(.headline)
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
            }
        }
        }
    }

    // MARK: - Waypoints

    private func waypointLabel(_ index: Int) -> String {
        if index == 0 { return "Start" }
        if index == waypoints.count - 1 { return "End" }
        return "Stop \(index)"
    }

    private var waypointSummary: String {
        switch waypoints.count {
        case 1: return "Start set — add at least one more point."
        default: return "\(waypoints.count) points: start, \(max(waypoints.count - 2, 0)) stop(s), end."
        }
    }

    private func addWaypoint() {
        guard let center = visibleCenter else {
            alertText = "Pan the map so a spot is centered, then add it."
            return
        }
        waypoints.append(RouteWaypoint(coordinate: center))
        routeCoordinates = []
    }

    private func clearAll() {
        waypoints = []
        routeCoordinates = []
        currentPosition = nil
    }

    // MARK: - Route computation

    private func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    private func computeRoute() async {
        guard waypoints.count >= 2 else { return }
        isComputing = true
        defer { isComputing = false }

        var coords: [CLLocationCoordinate2D] = []
        var totalTime: TimeInterval = 0
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.coordinate))
            request.transportType = speedMode == .manual && manualSpeedMps * 3.6 <= 12 ? .walking : .automobile

            if let response = try? await MKDirections(request: request).calculate(),
               let route = response.routes.first {
                coords.append(contentsOf: coordinates(from: route.polyline))
                totalTime += route.expectedTravelTime
            } else {
                coords.append(a.coordinate)
                coords.append(b.coordinate)
            }
        }

        routeCoordinates = coords
        routeExpectedTime = totalTime
        if let region = region(fitting: coords) {
            cameraPosition = .region(region)
        }
    }

    private func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.01),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Realistic playback

    /// Builds samples that total ~`totalDuration` (Apple's real-world ETA) while slowing
    /// near turns and adding speed variance — so a route takes the real amount of time.
    private func buildRealisticSamples(_ coords: [CLLocationCoordinate2D], totalDuration: TimeInterval, fallbackSpeed: Double) -> [RoutePlaybackSample] {
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

        // Slow-down weight per segment from the turn angle at its end vertex.
        var weights: [Double] = []
        var weightedDist = 0.0
        for i in 0..<segDist.count {
            var w = 1.0
            if i + 2 < coords.count {
                let b1 = bearing(coords[i], coords[i + 1])
                let b2 = bearing(coords[i + 1], coords[i + 2])
                var turn = abs(b2 - b1)
                if turn > 180 { turn = 360 - turn }
                w = max(1.0 - min(turn / 120.0, 1.0) * 0.65, 0.35)   // sharper turn -> slower
            }
            weights.append(w)
            weightedDist += segDist[i] / w
        }

        let target = totalDuration > 0 ? totalDuration : totalDist / max(fallbackSpeed, 1)
        let baseSpeed = weightedDist / max(target, 1)   // scale so total playback ≈ target
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
                let variedDelay = stepDelay * Double.random(in: 0.88...1.12)   // ±12% speed variance
                samples.append(RoutePlaybackSample(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    delayFromPrevious: variedDelay
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

    // MARK: - Playback

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    private func startDrive() async {
        guard routeCoordinates.count > 1 else { return }
        guard pairingFilePath() != nil else {
            alertText = "Import a pairing file in Settings first."
            return
        }

        isComputing = true
        let samples: [RoutePlaybackSample]
        switch speedMode {
        case .realistic:
            samples = buildRealisticSamples(
                routeCoordinates,
                totalDuration: routeExpectedTime,
                fallbackSpeed: manualMetersPerSecond
            )
        case .speedLimit:
            samples = await prefetchRoutePlaybackSamples(
                displayCoordinates: routeCoordinates,
                fallbackSpeedMetersPerSecond: manualMetersPerSecond
            )
        case .manual:
            samples = buildPlaybackSamples(
                from: routeCoordinates,
                speedWays: [],
                fallbackSpeedMetersPerSecond: manualMetersPerSecond
            )
        }
        isComputing = false

        guard samples.count > 1 else {
            alertText = "Couldn't build a playback path for this route."
            return
        }

        isDriving = true
        isPaused = false
        progress = 0
        SimulationSession.shared.started()

        let totalPlanned = samples.reduce(0) { $0 + $1.delayFromPrevious }
        playbackTask = Task {
            var elapsed = 0.0
            let total = samples.count
            for (index, sample) in samples.enumerated() {
                if Task.isCancelled { break }
                while isPaused && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if Task.isCancelled { break }
                if sample.delayFromPrevious > 0 {
                    let scaled = sample.delayFromPrevious / max(playbackRate, 0.1)
                    try? await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
                }
                if Task.isCancelled { break }
                elapsed += sample.delayFromPrevious
                let outgoing = jitterEnabled ? LocationJitter.apply(sample.coordinate) : sample.coordinate
                send(outgoing)
                currentPosition = sample.coordinate
                cameraPosition = .camera(MapCamera(centerCoordinate: sample.coordinate, distance: 1_500))
                progress = Double(index + 1) / Double(total)
                remainingSeconds = max(totalPlanned - elapsed, 0) / max(playbackRate, 0.1)
            }
            if !Task.isCancelled { isDriving = false }
        }
    }

    private func stopDrive() {
        // Global stop: clears device location + broadcasts reset.
        SimulationSession.shared.stopAll()
    }

    private func localReset() {
        playbackTask?.cancel()
        playbackTask = nil
        isDriving = false
        isPaused = false
        progress = 0
    }

    private func send(_ coord: CLLocationCoordinate2D) {
        guard let path = pairingFilePath() else { return }
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, coord.latitude, coord.longitude, path)
        }
    }
}

#Preview {
    RouteModeView()
}
