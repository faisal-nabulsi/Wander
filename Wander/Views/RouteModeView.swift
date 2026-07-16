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

/// How the PATH between waypoints is generated + how fast the pin moves along it —
/// like choosing driving / transit / walking in Google Maps.
///
/// DRIVE/WALK/CYCLE/TRANSIT snap to roads via MKDirections; BOAT/PLANE bypass roads
/// and fly a great-circle track. `cruiseSpeedMps` paces the playback sampler for the
/// mode; `usesRoadRouting` decides whether MKDirections is consulted at all.
private enum RouteTransportMode: String, CaseIterable, Identifiable {
    case drive
    case walk
    case cycle
    case transit
    case boat
    case plane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drive:   return L("route.mode.drive", fallback: "Drive")
        case .walk:    return L("route.mode.walk", fallback: "Walk")
        case .cycle:   return L("route.mode.cycle", fallback: "Cycle")
        case .transit: return L("route.mode.transit", fallback: "Transit")
        case .boat:    return L("route.mode.boat", fallback: "Boat")
        case .plane:   return L("route.mode.plane", fallback: "Plane")
        }
    }

    var icon: String {
        switch self {
        case .drive:   return "car.fill"
        case .walk:    return "figure.walk"
        case .cycle:   return "bicycle"
        case .transit: return "tram.fill"
        case .boat:    return "ferry.fill"
        case .plane:   return "airplane"
        }
    }

    /// Whether the coordinate list comes from the road-routing engine (MKDirections).
    /// BOAT/PLANE generate great-circle coordinates instead.
    var usesRoadRouting: Bool {
        switch self {
        case .drive, .walk, .cycle, .transit: return true
        case .boat, .plane: return false
        }
    }

    /// MKDirections transport type for the road-routing modes. Walk uses walking
    /// directions; everything else routes as a car (cycle/transit ride the road network).
    var mapKitTransportType: MKDirectionsTransportType {
        self == .walk ? .walking : .automobile
    }

    /// Cruise speed in m/s used to pace playback. Road modes still honor the real ETA
    /// when available; this is the fallback / the pace for the great-circle modes.
    var cruiseSpeedMps: Double {
        switch self {
        case .drive:   return 50_000.0 / 3_600.0   // ~50 km/h
        case .walk:    return 5_000.0 / 3_600.0     // ~5 km/h
        case .cycle:   return 18_000.0 / 3_600.0    // ~18 km/h
        case .transit: return 40_000.0 / 3_600.0    // ~40 km/h
        case .boat:    return 35_000.0 / 3_600.0    // ~35 km/h
        case .plane:   return 850_000.0 / 3_600.0   // ~850 km/h
        }
    }

    /// TRANSIT inserts brief dwell pauses to mimic station/bus stops.
    var insertsDwellStops: Bool { self == .transit }
}

/// Spherical (great-circle) interpolation between two coordinates, used by BOAT/PLANE
/// which do NOT snap to roads. Returns `steps + 1` points from `a` to `b` inclusive,
/// following the shortest path over the sphere so long lines curve correctly.
private func greatCirclePath(from a: CLLocationCoordinate2D,
                             to b: CLLocationCoordinate2D,
                             steps: Int) -> [CLLocationCoordinate2D] {
    let n = max(steps, 1)
    let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
    let lat2 = b.latitude * .pi / 180, lon2 = b.longitude * .pi / 180

    // Angular distance between the two points (haversine).
    let dLat = lat2 - lat1, dLon = lon2 - lon1
    let h = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    let delta = 2 * asin(min(1, sqrt(h)))

    // Coincident points (or numerically tiny separation): just return the endpoints.
    guard delta > 1e-9 else { return [a, b] }

    var out: [CLLocationCoordinate2D] = []
    out.reserveCapacity(n + 1)
    for i in 0...n {
        let f = Double(i) / Double(n)
        let sinDelta = sin(delta)
        let A = sin((1 - f) * delta) / sinDelta
        let B = sin(f * delta) / sinDelta
        let x = A * cos(lat1) * cos(lon1) + B * cos(lat2) * cos(lon2)
        let y = A * cos(lat1) * sin(lon1) + B * cos(lat2) * sin(lon2)
        let z = A * sin(lat1) + B * sin(lat2)
        let lat = atan2(z, sqrt(x * x + y * y))
        let lon = atan2(y, x)
        out.append(CLLocationCoordinate2D(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi))
    }
    return out
}

struct RouteModeView: View {
    @State private var waypoints: [RouteWaypoint] = []
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    // When true the camera keeps the moving pin on screen — but preserves YOUR zoom level and
    // only recenters when the pin nears the edge. Tap the follow button to fully unlock it.
    @State private var followCamera = true
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var showPaywall = false
    @StateObject private var currentLocation = CurrentLocation()
    @State private var visibleCenter: CLLocationCoordinate2D?
    @State private var currentPosition: CLLocationCoordinate2D?

    @State private var speedMode: RouteSpeedMode = .realistic
    @State private var transportMode: RouteTransportMode = .drive   // path-generation + speed (Google-Maps style)
    @State private var loopRoute = false   // Pro: re-run the route from the start when it finishes
    @State private var manualSpeedMps: Double = 50_000.0 / 3_600.0   // default 50 km/h
    @State private var routeExpectedTime: TimeInterval = 0            // real-world ETA from MKDirections
    @AppStorage("useMph") private var useMph = false
    @AppStorage("jitterEnabled") private var jitterEnabled = false
    /// "Weather-aware pace" (iOS parity with Android): when on, the destination
    /// weather (read once at route start) applies a speed multiplier — clear 1.0,
    /// rain/drizzle 0.85, snow 0.70. Calm no-op when weather is unavailable.
    @AppStorage("weatherAwarePace") private var weatherAwarePace = false

    @State private var isPaused = false
    @State private var playbackRate: Double = 1.0
    @State private var progress: Double = 0
    @State private var remainingSeconds: TimeInterval = 0

    @State private var isComputing = false
    @State private var isDriving = false
    @State private var playbackTask: Task<Void, Never>?

    @State private var alertText: String?

    // Save-loop builder (Pro): named user routes.
    @StateObject private var savedRoutes = SavedRoutesStore()
    @State private var showSaveRouteSheet = false
    @State private var newRouteName = ""
    @State private var showSavedRoutes = false

    // Record-a-real-route (Pro): capture the device's REAL GPS while physically moving,
    // then replay later. Recording the real provider only makes sense when NOT spoofing.
    @StateObject private var recorder = RouteRecorder()
    @ObservedObject private var simSession = SimulationSession.shared
    @State private var showSaveRecordingSheet = false
    @State private var newRecordingName = ""
    @State private var pendingRecordingCoords: [CLLocationCoordinate2D] = []
    @State private var pendingRecordingTimes: [Double] = []

    // Flight Planner (free, no API): pick two airports (searchable by IATA/name), optionally
    // generate plausible flights across a time range, then fly the great-circle PLANE route.
    @State private var showFlightPlanner = false

    // The user's own saved/favorite places (their custom-named bookmarks). Handed to the AI /
    // offline routine generator as REAL anchors so the day is built around their spots (Home,
    // Gym, Grandma) instead of invented ones.
    @StateObject private var savedPlaces = SavedPlacesStore()

    // AI "believable day" (Pro): the Worker generates a plausible day of stops we can replay/save.
    @State private var isGeneratingAI = false
    @State private var aiPlaces: [AIRoutinePlace] = []
    @State private var showAIRoutine = false
    // True when the shown day is an OFFLINE routine (cached real day or on-device generated),
    // so the sheet can badge it "Offline routine — reconnect for AI-crafted ones".
    @State private var aiRoutineIsOffline = false
    // Optional persona/day prompt (e.g. "a nurse on a night shift"), sent as the `style` field.
    // Empty prompt + "Surprise me" sends NO style so the server randomizes the persona.
    @State private var aiStylePrompt = ""

    private var manualMetersPerSecond: Double { max(manualSpeedMps, 1) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                controls
            }
            .navigationTitle(L("route.title", fallback: "Route"))
            .alert(L("route.title", fallback: "Route"), isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
                Button(L("action.ok", fallback: "OK"), role: .cancel) {}
            } message: { Text(alertText ?? "") }
            // Don't stop an active drive just because the user switched tabs — only reset
            // when idle. The explicit Stop button / global stop still tears it down.
            .onDisappear { if !SimulationSession.shared.isActive { localReset() } }
            .onReceive(NotificationCenter.default.publisher(for: .stopSimulationRequested)) { _ in
                localReset()
            }
            // Reload the routes store when a backup restore (or any writer) changes it, so a
            // later save can't persist a stale in-memory array and clobber restored routes.
            .onReceive(NotificationCenter.default.publisher(for: .savedRoutesDidChange)) { _ in
                savedRoutes.reload()
            }
            .onAppear {
                currentLocation.request()
                savedPlaces.reload()   // load the user's saved spots to anchor the AI day
            }
            // Keep the saved-places snapshot fresh when the Places tab / sync writes to the store,
            // so a routine generated later anchors on the user's current spots.
            .onReceive(NotificationCenter.default.publisher(for: .placesDidChange)) { _ in
                savedPlaces.reload()
            }
            .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
            .sheet(isPresented: $showSaveRouteSheet) { saveRouteSheet }
            .sheet(isPresented: $showSaveRecordingSheet) { saveRecordingSheet }
            .sheet(isPresented: $showSavedRoutes) { savedRoutesSheet }
            .sheet(isPresented: $showAIRoutine) { aiRoutineSheet }
            .sheet(isPresented: $showFlightPlanner) {
                FlightPlannerView { departure, arrival in
                    flyAirports(from: departure, to: arrival)
                }
            }
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
            visibleRegion = context.region
        }
        .overlay(alignment: .center) {
            if !isDriving { MapCrosshair() }
        }
        .overlay(alignment: .topTrailing) {
            if isDriving { followButton }
        }
        .ignoresSafeArea()
    }

    /// Toggles camera-follow during a drive. On → tracks the pin (fixed zoom). Off → the map
    /// is yours to zoom out / pan; tap again to snap back and resume following.
    private var followButton: some View {
        Button {
            followCamera.toggle()
            if followCamera, let currentPosition {
                let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(center: currentPosition, span: span))
                }
            }
        } label: {
            Image(systemName: followCamera ? "location.fill" : "location.slash.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(followCamera ? .white : Wander.brand)
                .frame(width: 44, height: 44)
                .background(followCamera ? Wander.brand : Color(.systemBackground), in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .padding(.top, 110)
        .padding(.trailing, 16)
        .accessibilityLabel(followCamera ? "Stop following" : "Follow location")
    }

    private var controls: some View {
        WanderCard {
        ScrollView {
        VStack(spacing: 12) {
            if isComputing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized: "route.working", fallback: "Working…").font(.caption).foregroundStyle(.secondary)
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
                        Label(String(format: L("route.add_point", fallback: "Add point (%d)"), waypoints.count), systemImage: Wander.Icon.add)
                    }
                    Spacer()
                    if !waypoints.isEmpty {
                        Button(role: .destructive) { clearAll() } label: {
                            Label(L("route.clear", fallback: "Clear"), systemImage: Wander.Icon.clear)
                        }
                    }
                }
                .font(.subheadline)

                if !waypoints.isEmpty {
                    Text(waypointSummary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                reorderableStopsList

                modePicker

                // The realistic/speed-limit/manual pacing picker only applies to the
                // road-following DRIVE/WALK modes. The other modes run at their own cruise
                // speed, so we show a short explanation instead of the speed controls.
                if transportMode == .drive || transportMode == .walk {

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

                } else if let hint = modeHint {
                    // CYCLE/TRANSIT/BOAT/PLANE explanation (great-circle + no-altitude note for PLANE).
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // PLANE mode gets a friendlier airport-based endpoint picker: choose a
                // departure + arrival airport (searchable by IATA/name) and fly the same
                // great-circle plane route from those two coordinates.
                if transportMode == .plane {
                    Button { showFlightPlanner = true } label: {
                        Label(L("flight.open", fallback: "Flight Planner"), systemImage: "airplane.departure")
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Wander.brand)
                }

                Toggle(isOn: Binding(
                    get: { loopRoute },
                    set: { newValue in
                        // Pro feature: free/trial users see the toggle but hitting it opens the upsell.
                        if newValue && !License.shared.isLicensed {
                            showPaywall = true
                            return
                        }
                        loopRoute = newValue
                    }
                )) {
                    Label(L("route.loop", fallback: "Loop route"), systemImage: "repeat")
                        .font(.subheadline)
                }
                .tint(Wander.brand)

                Toggle(isOn: $weatherAwarePace) {
                    Label(L("route.weather_pace", fallback: "Weather-aware pace"), systemImage: "cloud.rain")
                        .font(.subheadline)
                }
                .tint(Wander.brand)
                if weatherAwarePace {
                    Text(localized: "route.weather_pace.footer",
                         fallback: "Slows the drive in rain or snow at the destination — checked once when the route starts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                saveLoopControls

                recordControls

                aiRoutineControls

                HStack(spacing: 10) {
                    Button { Task { await computeRoute() } } label: {
                        Label(L("route.preview", fallback: "Preview"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(waypoints.count < 2 || isComputing)

                    Button { Task { await startDrive() } } label: {
                        Label(L("route.drive", fallback: "Drive"), systemImage: Wander.Icon.play)
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
                        Text(String(format: L("route.time_left", fallback: "~%d min left"), Int((remainingSeconds / 60).rounded())))
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
                        Label(L("route.stop", fallback: "Stop"), systemImage: Wander.Icon.stop)
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
        .frame(maxHeight: UIScreen.main.bounds.height * 0.55)
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

    // MARK: - Transport mode UI

    /// Google-Maps-style transport picker: DRIVE / WALK / CYCLE / TRANSIT / BOAT / PLANE.
    /// Changing the mode invalidates the previewed path (it must be regenerated for the
    /// new mode's routing engine + speed).
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized: "route.mode", fallback: "Mode")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Mode", selection: $transportMode) {
                ForEach(RouteTransportMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: transportMode) { _, _ in
                // The old path was built for a different engine/speed — clear it so the
                // user re-previews (or a saved run re-computes) for the new mode.
                routeCoordinates = []
                routeExpectedTime = 0
            }
        }
    }

    /// Explanation shown under the picker for the non-DRIVE/WALK modes (DRIVE/WALK show
    /// the existing pacing controls instead). PLANE includes the iOS no-altitude note.
    private var modeHint: String? {
        switch transportMode {
        case .drive, .walk: return nil
        case .cycle:   return nil
        case .transit: return L("route.mode.transit_hint", fallback: "Follows the road route at transit speed with brief stops, like a bus or train.")
        case .boat:    return L("route.mode.boat_hint", fallback: "Sails a straight line between points at boat speed — no roads.")
        case .plane:   return L("route.mode.plane_hint", fallback: "Flies a great-circle path from the first to the last point at flight speed. Altitude can't be simulated on iOS, so only the path and speed are applied.")
        }
    }

    // MARK: - Reorderable stops

    /// The stops list, drag-to-reorder like Google Maps. Reordering mutates `waypoints`
    /// and clears the previewed path so playback re-routes to follow the new order.
    @ViewBuilder private var reorderableStopsList: some View {
        if waypoints.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(localized: "route.stops", fallback: "Stops")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { reverseWaypoints() } label: {
                        Label(L("route.reverse", fallback: "Reverse"), systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }
                    EditButton()
                        .font(.caption)
                }
                List {
                    ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, wp in
                        HStack(spacing: 10) {
                            Image(systemName: index == 0 ? "flag.fill"
                                  : (index == waypoints.count - 1 ? "flag.checkered" : "\(min(index, 50)).circle.fill"))
                                .foregroundStyle(index == 0 ? .green : (index == waypoints.count - 1 ? .red : .orange))
                            Text(stopRowLabel(index: index, coordinate: wp.coordinate))
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                    .onMove(perform: moveWaypoints)
                    .onDelete(perform: deleteWaypoints)
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(waypoints.count) * 44 + 8, 200))
                .scrollContentBackground(.hidden)

                Text(localized: "route.reorder_hint",
                     fallback: "Drag to reorder your stops — the route follows the new order.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func stopRowLabel(index: Int, coordinate: CLLocationCoordinate2D) -> String {
        let name = waypointLabel(index)
        return String(format: "%@  (%.4f, %.4f)", name, coordinate.latitude, coordinate.longitude)
    }

    /// Reorder waypoints, then invalidate the previewed path so the next preview/drive
    /// re-routes to follow the new order.
    private func moveWaypoints(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)
        routeCoordinates = []
        routeExpectedTime = 0
    }

    private func deleteWaypoints(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        routeCoordinates = []
        routeExpectedTime = 0
    }

    /// Flip the waypoint order (B→A→…) so a saved commute can be run in the
    /// opposite direction — work-to-home instead of home-to-work. Invalidates the
    /// previewed path so the next Preview/Drive re-routes along the new order.
    private func reverseWaypoints() {
        guard waypoints.count >= 2 else { return }
        waypoints.reverse()
        routeCoordinates = []
        routeExpectedTime = 0
        if let region = region(fitting: waypoints.map(\.coordinate)) {
            cameraPosition = .region(region)
        }
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

        // BOAT/PLANE bypass road snapping entirely and build a great-circle track.
        if !transportMode.usesRoadRouting {
            let coords = greatCircleCoordinates()
            routeCoordinates = coords
            // Great-circle modes have no MKDirections ETA; pace by their cruise speed.
            routeExpectedTime = 0
            if let region = region(fitting: coords) {
                cameraPosition = .region(region)
            }
            return
        }

        var coords: [CLLocationCoordinate2D] = []
        var totalTime: TimeInterval = 0
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.coordinate))
            request.transportType = transportMode.mapKitTransportType

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
        // DRIVE/WALK follow the real ETA (existing behavior). CYCLE/TRANSIT re-pace to
        // their own cruise speed, so drop MKDirections' car ETA for them.
        routeExpectedTime = (transportMode == .drive || transportMode == .walk) ? totalTime : 0
        if let region = region(fitting: coords) {
            cameraPosition = .region(region)
        }
    }

    /// Great-circle coordinate list for BOAT/PLANE (no road snapping).
    /// BOAT interpolates between every consecutive waypoint; PLANE flies straight from
    /// the first waypoint to the last. Point density scales with distance for a smooth line.
    private func greatCircleCoordinates() -> [CLLocationCoordinate2D] {
        func stepsFor(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Int {
            let meters = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            // ~1 point per 2 km, clamped so short hops still get a handful and long
            // hauls stay smooth without exploding the sample count.
            return min(max(Int(meters / 2000), 8), 800)
        }

        switch transportMode {
        case .plane:
            guard let first = waypoints.first?.coordinate,
                  let last = waypoints.last?.coordinate else { return [] }
            return greatCirclePath(from: first, to: last, steps: stepsFor(first, last))
        default: // .boat (and any future non-road mode)
            var coords: [CLLocationCoordinate2D] = []
            for (a, b) in zip(waypoints, waypoints.dropFirst()) {
                let seg = greatCirclePath(from: a.coordinate, to: b.coordinate, steps: stepsFor(a.coordinate, b.coordinate))
                // Avoid duplicating the shared vertex between consecutive segments.
                coords.append(contentsOf: coords.isEmpty ? seg : Array(seg.dropFirst()))
            }
            return coords
        }
    }

    /// True when the coordinate sits well inside the visible map (within the middle ~60%),
    /// so following can leave the camera alone and not fight the user's zoom/pan.
    private func regionComfortablyContains(_ coord: CLLocationCoordinate2D) -> Bool {
        guard let region = visibleRegion else { return false }
        let latMargin = region.span.latitudeDelta * 0.3
        let lonMargin = region.span.longitudeDelta * 0.3
        return abs(coord.latitude - region.center.latitude) < latMargin
            && abs(coord.longitude - region.center.longitude) < lonMargin
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

    /// Speed multiplier for a WMO weather code (Open-Meteo), matching Android's
    /// weather-aware pacing: clear/cloudy 1.0, drizzle/rain/showers 0.85, any snow
    /// 0.70. Anything else (fog, thunderstorm, unknown) stays at 1.0 — calm no-op.
    private static func weatherPaceMultiplier(forWeatherCode code: Int) -> Double {
        switch code {
        case 51, 53, 55, 56, 57,       // drizzle (incl. freezing)
             61, 63, 65, 66, 67,       // rain (incl. freezing)
             80, 81, 82:               // rain showers
            return 0.85
        case 71, 73, 75, 77,           // snowfall
             85, 86:                   // snow showers
            return 0.70
        default:
            return 1.0                 // clear, cloudy, fog, thunderstorm, unknown
        }
    }

    /// Read the destination weather once and return the pacing multiplier. Returns
    /// 1.0 (no-op) when the toggle is off, there's no route, or the fetch fails.
    private func weatherPaceMultiplier() async -> Double {
        guard weatherAwarePace, let destination = routeCoordinates.last else { return 1.0 }
        guard let code = await LocationInfoService.fetchWeatherCode(
            lat: destination.latitude,
            lng: destination.longitude
        ) else {
            return 1.0   // unavailable → calm no-op
        }
        return Self.weatherPaceMultiplier(forWeatherCode: code)
    }

    private func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    /// Total meters along an ordered coordinate list.
    private func routeDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 0..<(coords.count - 1) {
            total += CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                .distance(from: CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude))
        }
        return total
    }

    /// TRANSIT: insert brief dwell pauses (a few seconds) roughly every 60–90s of travel,
    /// mimicking station/bus stops. Walks the already-timed samples and, each time the
    /// accumulated travel time crosses a randomized interval, stretches that sample's delay
    /// by a short dwell. No transit API needed — this just re-times the road samples.
    private func insertTransitDwells(_ samples: [RoutePlaybackSample]) -> [RoutePlaybackSample] {
        guard samples.count > 2 else { return samples }
        var out: [RoutePlaybackSample] = []
        out.reserveCapacity(samples.count)
        var sinceLastStop = 0.0
        var nextStopAt = Double.random(in: 60...90)
        for (i, s) in samples.enumerated() {
            sinceLastStop += s.delayFromPrevious
            // Don't dwell on the very first or very last sample.
            if sinceLastStop >= nextStopAt, i > 0, i < samples.count - 1 {
                let dwell = Double.random(in: 3...6)
                out.append(RoutePlaybackSample(coordinate: s.coordinate,
                                               delayFromPrevious: s.delayFromPrevious + dwell))
                sinceLastStop = 0
                nextStopAt = Double.random(in: 60...90)
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: - Playback

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// Drive the route. Pass `prebuiltSamples` to play an already-timed track (a recorded
    /// route replayed at its real pace) — this bypasses speed-mode sample building and the
    /// road-following coordinates entirely.
    private func startDrive(prebuiltSamples: [RoutePlaybackSample]? = nil) async {
        let usingPrebuilt = prebuiltSamples != nil
        guard usingPrebuilt || routeCoordinates.count > 1 else { return }
        guard pairingFilePath() != nil else {
            alertText = "Import a pairing file in Settings first."
            return
        }
        if !License.shared.isLicensed && !TrialManager.shared.canUse(.route) {
            showPaywall = true
            return
        }

        isComputing = true
        var samples: [RoutePlaybackSample]
        if let prebuiltSamples {
            samples = prebuiltSamples
        } else if transportMode == .drive || transportMode == .walk {
            // DRIVE/WALK behave exactly as today: the speed-mode picker chooses the pacing.
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
        } else {
            // CYCLE/TRANSIT/BOAT/PLANE: pace along the coordinate list at the mode's
            // cruise speed (great-circle modes have no ETA). TRANSIT adds dwell pauses.
            var built = buildRealisticSamples(
                routeCoordinates,
                totalDuration: routeCoordinates.count > 1
                    ? routeDistance(routeCoordinates) / transportMode.cruiseSpeedMps
                    : 0,
                fallbackSpeed: transportMode.cruiseSpeedMps
            )
            if transportMode.insertsDwellStops {
                built = insertTransitDwells(built)
            }
            samples = built
        }

        // Weather-aware pace (parity with Android): read the destination weather
        // ONCE at route start and slow the whole run down for rain/snow. A
        // multiplier < 1 means slower travel, i.e. longer per-sample delays.
        let paceMultiplier = await weatherPaceMultiplier()
        if paceMultiplier < 1.0 {
            samples = samples.map {
                RoutePlaybackSample(
                    coordinate: $0.coordinate,
                    delayFromPrevious: $0.delayFromPrevious / paceMultiplier
                )
            }
        }
        isComputing = false

        guard samples.count > 1 else {
            alertText = "Couldn't build a playback path for this route."
            return
        }

        isDriving = true
        isPaused = false
        followCamera = true   // each drive starts tracking the pin
        progress = 0
        // Start the drive showing the whole route, not zoomed hard into the start pin.
        let fitCoords = usingPrebuilt ? samples.map(\.coordinate) : routeCoordinates
        if let region = region(fitting: fitCoords) {
            withAnimation { cameraPosition = .region(region) }
            visibleRegion = region
        }
        SimulationSession.shared.started()
        // Adventure Sync: open a fresh walk window for this drive (no-op unless
        // opted in). Per-sample deltas below feed the incremental Health writer.
        AdventureSyncManager.shared.beginWalk()
        if !License.shared.isLicensed { TrialManager.shared.chargeRoute() }

        let totalPlanned = samples.reduce(0) { $0 + $1.delayFromPrevious }
        let shouldLoop = loopRoute
        playbackTask = Task {
            let total = samples.count
            // One full pass over the route. When looping, we re-run it from the
            // first sample and keep going until the user stops (task cancelled).
            repeat {
                var elapsed = 0.0
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
                    // "Hold perfectly still" disables jitter; otherwise honor the jitter toggle.
                    let frozen = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
                    let outgoing = (!frozen && jitterEnabled) ? LocationJitter.apply(sample.coordinate) : sample.coordinate
                    send(outgoing)
                    currentPosition = sample.coordinate
                    // Adventure Sync: mirror the SIMULATED movement (true path
                    // coordinate, not the jittered one) into Health incrementally as
                    // the drive advances. No-op unless the user opted in.
                    AdventureSyncManager.shared.recordSimulatedMovement(to: sample.coordinate)
                    // Follow without hijacking zoom: only recenter (keeping the user's current span)
                    // when the pin drifts near the edge of what's on screen.
                    if followCamera, !regionComfortablyContains(sample.coordinate) {
                        let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                        withAnimation { cameraPosition = .region(MKCoordinateRegion(center: sample.coordinate, span: span)) }
                    }
                    progress = Double(index + 1) / Double(total)
                    remainingSeconds = max(totalPlanned - elapsed, 0) / max(playbackRate, 0.1)
                }
            } while shouldLoop && !Task.isCancelled
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
        // Adventure Sync: flush the tail of the drive and clear accumulation.
        AdventureSyncManager.shared.endWalk()
        isDriving = false
        isPaused = false
        progress = 0
    }

    private func send(_ coord: CLLocationCoordinate2D) {
        guard let path = pairingFilePath() else { return }
        // "Approximate location": stable per-session ~3–5 km offset. No-op when off.
        let coord = CoarseLocation.apply(coord)
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, coord.latitude, coord.longitude, path)
        }
    }

    // MARK: - Record a real route (Pro)

    /// True when a location spoof/simulation is currently active. Recording the REAL GPS
    /// while spoofing is meaningless (the OS location is the spoofed one), so we disable it.
    private var spoofActive: Bool { simSession.isActive }

    /// Record / Stop-and-save controls. Pro-gated (free/trial users get the paywall on tap),
    /// and DISABLED while a spoof is active with a clear "stop spoofing to record" hint.
    @ViewBuilder private var recordControls: some View {
        VStack(spacing: 6) {
            if recorder.isRecording {
                Button(role: .destructive) { finishRecording() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle.fill")
                        Text("Stop & save recording")
                        Spacer()
                        Text("\(recorder.fixCount) pts")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

                Text("Recording your REAL location — \(recordedDistanceLabel). Move along your real route, then stop to save it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button { beginRecording() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                        Text("Record a real route")
                        if !License.shared.isLicensed {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Wander.brand)
                .disabled(spoofActive)

                if spoofActive {
                    Text("Stop spoofing to record your real route — recording captures your device's real GPS, not the simulated location.")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Captures your device's real GPS + timing while you physically move, so you can replay a believable commute later.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var recordedDistanceLabel: String {
        let m = recorder.distanceMeters
        if useMph {
            let miles = m / 1609.34
            return miles < 0.1 ? String(format: "%.0f ft", m * 3.28084) : String(format: "%.2f mi", miles)
        } else {
            return m < 1000 ? String(format: "%.0f m", m) : String(format: "%.2f km", m / 1000)
        }
    }

    /// Start recording real GPS. Pro-gated; blocked while spoofing.
    private func beginRecording() {
        if !License.shared.isLicensed { showPaywall = true; return }
        guard !spoofActive else {
            alertText = "Stop the active simulation before recording — recording needs your real location."
            return
        }
        recorder.requestAuthorization()
        guard recorder.isAuthorized else {
            alertText = "Allow location access to record your real route (Settings → Wander → Location)."
            return
        }
        recorder.start()
    }

    /// Stop recording, stash the captured track, and prompt for a name to save it.
    private func finishRecording() {
        let fixes = recorder.stop()
        guard fixes.count >= 2 else {
            alertText = "That recording was too short to save — no usable GPS points were captured."
            return
        }
        pendingRecordingCoords = fixes.map(\.coordinate)
        pendingRecordingTimes = fixes.map { $0.timestamp.timeIntervalSince1970 }
        newRecordingName = defaultRecordingName()
        showSaveRecordingSheet = true
    }

    private func defaultRecordingName() -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm a"
        return "Commute \(df.string(from: Date()))"
    }

    private var saveRecordingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recording name", text: $newRecordingName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Saves \(pendingRecordingCoords.count) captured GPS points with their real timing. Replay it later from Saved routes to reproduce the pace.")
                }
            }
            .navigationTitle("Save Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        pendingRecordingCoords = []
                        pendingRecordingTimes = []
                        showSaveRecordingSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savedRoutes.addRecorded(
                            name: newRecordingName,
                            coordinates: pendingRecordingCoords,
                            timestamps: pendingRecordingTimes
                        )
                        pendingRecordingCoords = []
                        pendingRecordingTimes = []
                        showSaveRecordingSheet = false
                    }
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    // MARK: - Save-loop builder (Pro)

    /// "Save this route" + "Saved routes" entry points. Both are gated: non-licensed
    /// users see the buttons but tapping opens the paywall (matching the Loop toggle).
    @ViewBuilder private var saveLoopControls: some View {
        HStack(spacing: 10) {
            Button {
                if !License.shared.isLicensed { showPaywall = true; return }
                guard waypoints.count >= 2 else {
                    alertText = "Add at least two points before saving a route."
                    return
                }
                newRouteName = ""
                showSaveRouteSheet = true
            } label: {
                Label(L("route.save_route", fallback: "Save route"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity).frame(height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                if !License.shared.isLicensed { showPaywall = true; return }
                showSavedRoutes = true
            } label: {
                Label(String(format: L("route.saved_count", fallback: "Saved (%d)"), savedRoutes.routes.count), systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity).frame(height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.subheadline)
    }

    private var saveRouteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Route name", text: $newRouteName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Saves the \(waypoints.count) current points. Run it later and toggle Loop to repeat.")
                }
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSaveRouteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savedRoutes.add(name: newRouteName, coordinates: waypoints.map(\.coordinate))
                        showSaveRouteSheet = false
                    }
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private var savedRoutesSheet: some View {
        NavigationStack {
            List {
                if savedRoutes.routes.isEmpty {
                    Label("No saved routes yet. Build a route, then tap Save route.",
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedRoutes.routes) { route in
                        Button {
                            runSavedRoute(route)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: route.isRecorded ? "record.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath.fill")
                                    .font(.title3)
                                    .foregroundStyle(route.isRecorded ? .red : Wander.brand)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name).font(.body).foregroundStyle(.primary)
                                    Text(route.isRecorded
                                         ? "Recorded • \(route.pointCount) points"
                                         : "\(route.pointCount) points")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(route.isRecorded ? "Replay" : "Run", systemImage: Wander.Icon.play)
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Wander.brand)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { savedRoutes.delete($0) }
                }
            }
            .navigationTitle("Saved Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSavedRoutes = false }
                }
            }
        }
    }

    /// Load a saved route's waypoints, compute the road path, and start driving.
    /// Honors the current Loop toggle (combine with Loop to repeat). Pro-gated at entry.
    private func runSavedRoute(_ route: SavedRoute) {
        if !License.shared.isLicensed { showPaywall = true; return }
        let coords = route.coordinates
        guard coords.count >= 2 else {
            alertText = "This saved route doesn't have enough points to run."
            return
        }
        showSavedRoutes = false

        // Recorded real-GPS route: replay the captured track at its real pace, preserving
        // the recorded timing. We drive the dense GPS trail directly (no re-routing) and
        // show it as the on-map polyline so the pin follows the recording exactly.
        if route.isRecorded, let times = route.timestamps {
            let samples = buildRecordedPlaybackSamples(coordinates: coords, timestamps: times)
            guard samples.count > 1 else {
                alertText = "This recording doesn't have enough usable points to replay."
                return
            }
            waypoints = []
            routeCoordinates = coords
            Task { await startDrive(prebuiltSamples: samples) }
            return
        }

        // Builder route: route between the saved waypoints, then drive as usual.
        waypoints = coords.map { RouteWaypoint(coordinate: $0) }
        routeCoordinates = []
        Task {
            await computeRoute()
            guard routeCoordinates.count > 1 else {
                alertText = "Couldn't build a drivable path for this saved route."
                return
            }
            await startDrive()
        }
    }

    // MARK: - Flight Planner (free)

    /// Fly the great-circle PLANE route between two chosen airports. This is just a nicer
    /// airport-based way to set the two endpoints of the existing plane mode: it forces
    /// PLANE transport, drops the airport coordinates as the two waypoints, builds the
    /// same great-circle path, and starts playback (~850 km/h, no altitude on iOS).
    private func flyAirports(from departure: Airport, to arrival: Airport) {
        showFlightPlanner = false
        transportMode = .plane
        waypoints = [
            RouteWaypoint(coordinate: departure.coordinate),
            RouteWaypoint(coordinate: arrival.coordinate)
        ]
        routeCoordinates = []
        routeExpectedTime = 0
        Task {
            await computeRoute()
            guard routeCoordinates.count > 1 else {
                alertText = L("flight.no_path", fallback: "Couldn't build a flight path between those airports.")
                return
            }
            await startDrive()
        }
    }

    // MARK: - AI "believable day" (Pro)

    /// Entry point for the AI day generator. Pro-gated exactly like the other Pro controls:
    /// free/trial users see the button but tapping opens the paywall. On Pro, it POSTs the
    /// current map center (or device location) to the Worker and shows the returned stops.
    @ViewBuilder private var aiRoutineControls: some View {
        VStack(spacing: 8) {
            // Describe the day/persona. Leave blank and tap "Surprise me" for a random day.
            TextField("Describe the day (e.g. a nurse on a night shift)", text: $aiStylePrompt)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .disabled(isGeneratingAI)
                .onSubmit { generateAIRoutine(style: aiStylePrompt) }

            HStack(spacing: 10) {
                // Prompt path: uses whatever the user typed as the `style`.
                Button {
                    generateAIRoutine(style: aiStylePrompt)
                } label: {
                    HStack(spacing: 6) {
                        if isGeneratingAI {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGeneratingAI ? "Generating…" : "Generate day")
                        if !License.shared.isLicensed {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Wander.brand)
                .disabled(isGeneratingAI || aiStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Surprise-me path: sends NO style so the server randomizes the persona.
                Button {
                    generateAIRoutine(style: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dice.fill")
                        Text("Surprise me")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Wander.brand)
                .disabled(isGeneratingAI)
            }
        }
    }

    /// Resolve the request location (current map center, falling back to the device location),
    /// then call the Worker. Non-Pro users are sent to the paywall before any network call.
    /// `style` = a typed persona/day prompt, or nil for the "Surprise me" random path.
    private func generateAIRoutine(style: String?) {
        if !License.shared.isLicensed { showPaywall = true; return }
        guard let origin = visibleCenter ?? currentLocation.coordinate else {
            alertText = "Pan the map to where you want the day to start, then try again."
            return
        }
        let trimmedStyle = style?.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleToSend = (trimmedStyle?.isEmpty ?? true) ? nil : trimmedStyle
        // Anchor the day on the user's OWN saved places (their named bookmarks — NOT the QuickPlaces
        // landmark list). Deduped/trimmed/capped per the shared contract; omitted when empty.
        let namedPlaces = NamedPlace.fromBookmarks(savedPlaces.saved)
        isGeneratingAI = true
        Task {
            let result = await WanderAIRoutine.generate(at: origin, style: styleToSend,
                                                        namedPlaces: namedPlaces)
            isGeneratingAI = false
            switch result {
            case .success(let places, let source):
                aiPlaces = places
                aiRoutineIsOffline = source.isOffline
                showAIRoutine = true
            case .proRequired:
                showPaywall = true
            case .dailyLimit(let message):
                alertText = message
            case .notConfigured(let message):
                alertText = message
            case .failed(let message):
                alertText = message
            }
        }
    }

    /// The generated day: a labeled list with arrive/depart times, plus Replay (drops the stops
    /// as a drivable multi-stop route) and Save (into the same Saved Routes store).
    private var aiRoutineSheet: some View {
        NavigationStack {
            List {
                // Offline badge: shown only when the day came from the on-device fallback or the
                // cache (not a live AI day), so the user knows why it looks generic.
                if aiRoutineIsOffline {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.secondary)
                            Text(L("routine.offline_badge",
                                   fallback: "Offline routine — reconnect for AI-crafted ones"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(Array(aiPlaces.enumerated()), id: \.element.id) { index, place in
                        HStack(spacing: 12) {
                            Image(systemName: kindIcon(place.kind))
                                .font(.title3)
                                .foregroundStyle(Wander.brand)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(place.label)")
                                    .font(.body).foregroundStyle(.primary)
                                if let kind = place.kind, !kind.isEmpty {
                                    Text(kind.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let timeLabel = timeLabel(place) {
                                Text(timeLabel)
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                } header: {
                    Text("\(aiPlaces.count) stops")
                } footer: {
                    Text("Replay drives these stops as a route. Save keeps them in Saved Routes.")
                }
            }
            .navigationTitle("Your AI Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showAIRoutine = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        replayAIRoutine()
                    } label: {
                        Label("Replay", systemImage: Wander.Icon.play)
                    }
                    .disabled(aiPlaces.count < 2)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        saveAIRoutine()
                    } label: {
                        Label("Save to routes", systemImage: "square.and.arrow.down")
                    }
                    .disabled(aiPlaces.count < 2)
                }
            }
        }
    }

    /// Drop the AI stops in as waypoints and reuse the existing route playback (compute the road
    /// path, then drive). Same Pro/trial gating as any other drive happens inside startDrive().
    private func replayAIRoutine() {
        let coords = aiPlaces.map(\.coordinate)
        guard coords.count >= 2 else {
            alertText = "This day needs at least two stops to drive."
            return
        }
        showAIRoutine = false
        waypoints = coords.map { RouteWaypoint(coordinate: $0) }
        routeCoordinates = []
        Task {
            await computeRoute()
            guard routeCoordinates.count > 1 else {
                alertText = "Couldn't build a drivable path for this day."
                return
            }
            await startDrive()
        }
    }

    /// Persist the AI stops into the same Saved Routes store the manual builder uses.
    private func saveAIRoutine() {
        let coords = aiPlaces.map(\.coordinate)
        guard coords.count >= 2 else {
            alertText = "This day needs at least two stops to save."
            return
        }
        savedRoutes.add(name: "AI day", coordinates: coords)
        showAIRoutine = false
    }

    /// Combine arrive/depart into a compact right-aligned label, if the server sent either.
    private func timeLabel(_ place: AIRoutinePlace) -> String? {
        switch (place.arrive, place.depart) {
        case let (arrive?, depart?): return "\(arrive)\n\(depart)"
        case let (arrive?, nil): return arrive
        case let (nil, depart?): return depart
        default: return nil
        }
    }

    /// A best-effort SF Symbol for a place kind (purely cosmetic; unknown kinds get a pin).
    private func kindIcon(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "cafe", "coffee": return "cup.and.saucer.fill"
        case "restaurant", "food", "lunch", "dinner": return "fork.knife"
        case "park", "outdoors": return "leaf.fill"
        case "gym", "fitness": return "figure.run"
        case "shop", "shopping", "store": return "bag.fill"
        case "home": return "house.fill"
        case "work", "office": return "briefcase.fill"
        case "bar", "nightlife": return "wineglass.fill"
        default: return "mappin.circle.fill"
        }
    }
}

#Preview {
    RouteModeView()
}
