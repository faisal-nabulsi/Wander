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

/// One candidate route for the "2–3 options" picker (Google-Maps style). Populated only for
/// point-to-point trips (start + end, no intermediate stops), since neither Apple's alternate
/// routes nor Google's `computeAlternativeRoutes` combine with intermediate waypoints.
private struct RouteOption: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let expectedTime: TimeInterval   // seconds; 0 when unknown (great-circle / re-paced modes)
    let distanceMeters: Double
    let label: String                // e.g. "I-80 W" (Apple) or "via US-101" (Google) — may be ""
    /// Transit only: the walk / bus / rail legs for this option (empty for drive/walk/cycle).
    var steps: [WanderDirections.RouteStep] = []
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
    case plane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drive:   return L("route.mode.drive", fallback: "Drive")
        case .walk:    return L("route.mode.walk", fallback: "Walk")
        case .cycle:   return L("route.mode.cycle", fallback: "Cycle")
        case .transit: return L("route.mode.transit", fallback: "Transit")
        case .plane:   return L("route.mode.plane", fallback: "Plane")
        }
    }

    var icon: String {
        switch self {
        case .drive:   return "car.fill"
        case .walk:    return "figure.walk"
        case .cycle:   return "bicycle"
        case .transit: return "tram.fill"
        case .plane:   return "airplane"
        }
    }

    /// Whether the coordinate list comes from the road-routing engine (MKDirections).
    /// BOAT/PLANE generate great-circle coordinates instead.
    var usesRoadRouting: Bool {
        switch self {
        case .drive, .walk, .cycle, .transit: return true
        case .plane: return false
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
    /// How far UP (as a fraction of screen height) the crosshair + drop-point sit from centre, so the
    /// bottom controls card never covers the "add a point here" target — even with a full waypoint
    /// list. The map's `.ignoresSafeArea()` means map height ≈ screen height, so this fraction maps
    /// 1:1 to the latitude-span shift applied to `visibleCenter` below (keeping the dropped point
    /// exactly under the crosshair).
    private let crosshairLift: CGFloat = 0.18
    @State private var currentPosition: CLLocationCoordinate2D?

    @State private var speedMode: RouteSpeedMode = .realistic
    @State private var transportMode: RouteTransportMode = .drive   // path-generation + speed (Google-Maps style)
    @State private var loopRoute = false   // Pro: re-run the route from the start when it finishes
    @State private var manualSpeedMps: Double = 50_000.0 / 3_600.0   // default 50 km/h
    @State private var routeExpectedTime: TimeInterval = 0            // real-world ETA from MKDirections
    @State private var routeNotice: String?                          // e.g. "No route available" for a too-short plane trip
    /// The 2–3 route options for the current point-to-point trip and which one is selected.
    /// Empty for multi-stop / great-circle routes (the single previewed path is used directly).
    @State private var routeAlternatives: [RouteOption] = []
    @State private var selectedRouteIndex = 0
    @AppStorage("useMph") private var useMph = false
    @AppStorage("jitterEnabled") private var jitterEnabled = true
    // Same per-game context the Joystick + Games tabs read. Used ONLY to scope the hard speed
    // clamp during playback (see startDrive's loop): when the user is framing movement around a
    // location game we cap the effective route speed at that game's ban-triggering ceiling. Left OFF
    // for a general drive/flight so legitimate high-speed modes (highway drive, PLANE) aren't broken.
    @AppStorage("gameSpeedWarn") private var gameSpeedWarn = false
    @AppStorage("pogoGamePreset") private var gamePresetRaw = GamePreset.pokemonGo.rawValue
    private var gamePreset: GamePreset { GamePreset(rawValue: gamePresetRaw) ?? .pokemonGo }
    // Avoid options (Pro, Google Routes API) — only meaningful for Drive.
    @AppStorage("routeAvoidHighways") private var avoidHighways = false
    @AppStorage("routeAvoidTolls") private var avoidTolls = false
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
    /// Keyboard focus for the "Describe the day" field, so a Done button can dismiss it.
    @FocusState private var aiFieldFocused: Bool
    /// Collapses the secondary route options (loop/weather/save/record/AI) to keep the
    /// screen uncluttered — the core build-and-drive flow stays visible.
    @State private var showRouteExtras = false
    /// Presents the route-file importer (GPX / KML / GeoJSON / CSV → waypoints).
    @State private var showRouteFileImporter = false

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
            // Draw the unselected alternatives faded and the chosen one bold, so the picker
            // selection is visible on the map (Google-Maps style). Falls back to the single
            // previewed path for multi-stop / great-circle routes.
            if routeAlternatives.count > 1 {
                ForEach(Array(routeAlternatives.enumerated()), id: \.element.id) { idx, opt in
                    if idx != selectedRouteIndex && opt.coordinates.count > 1 {
                        MapPolyline(coordinates: opt.coordinates)
                            .stroke(.gray.opacity(0.5), lineWidth: 4)
                    }
                }
                if routeAlternatives.indices.contains(selectedRouteIndex),
                   routeAlternatives[selectedRouteIndex].coordinates.count > 1 {
                    MapPolyline(coordinates: routeAlternatives[selectedRouteIndex].coordinates)
                        .stroke(.blue, lineWidth: 5)
                }
            } else if routeCoordinates.count > 1 {
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
            // The crosshair is lifted up (below) so the bottom controls card can't cover it. The drop
            // point must follow the crosshair, not the map's geometric centre — so shift the reported
            // centre NORTH by the same fraction of the visible latitude span.
            visibleCenter = CLLocationCoordinate2D(
                latitude: context.region.center.latitude + crosshairLift * context.region.span.latitudeDelta,
                longitude: context.region.center.longitude)
            visibleRegion = context.region
        }
        .overlay(alignment: .center) {
            if !isDriving {
                MapCrosshair()
                    .offset(y: -UIScreen.main.bounds.height * crosshairLift)
            }
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
        VStack(spacing: 12) {
            if isComputing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized: "route.working", fallback: "Working…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let routeNotice {
                Label(routeNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isDriving {
                AddressSearchBar(placeholder: "Search to add a point") { coord, _ in
                    waypoints.append(RouteWaypoint(coordinate: coord))
                    routeCoordinates = []; routeAlternatives = []
                    if let region = region(fitting: waypoints.map(\.coordinate)) {
                        cameraPosition = .region(region)
                    }
                }
                HStack {
                    Button { addWaypoint() } label: {
                        Label(String(format: L("route.add_point", fallback: "Add point (%d)"), waypoints.count), systemImage: Wander.Icon.add)
                    }
                    Button { showRouteFileImporter = true } label: {
                        Label(L("route.import_file", fallback: "Import file"), systemImage: "square.and.arrow.down")
                    }
                    if waypoints.count >= 2 {
                        Button { showSaveRouteSheet = true } label: {
                            Label(L("route.save", fallback: "Save"), systemImage: "bookmark")
                        }
                    }
                    Spacer()
                    if !waypoints.isEmpty {
                        Button(role: .destructive) { clearAll() } label: {
                            Label(L("route.clear", fallback: "Clear"), systemImage: Wander.Icon.clear)
                        }
                    }
                }
                .font(.subheadline)
                .fileImporter(isPresented: $showRouteFileImporter,
                              allowedContentTypes: RouteFileImporter.contentTypes,
                              allowsMultipleSelection: false) { result in
                    handleRouteFileImport(result)
                }

                if !waypoints.isEmpty {
                    Text(waypointSummary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                reorderableStopsList

                modePicker

                // 2–3 route options (Google-Maps style) for point-to-point trips. Only shown
                // once a preview has produced more than one alternative.
                if routeAlternatives.count > 1 {
                    routeOptionsPicker
                }

                routeSummaryLine

                transitBreakdown

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

                // Secondary options collapsed by default so the screen stays uncluttered —
                // the core flow (points → mode → Preview/Drive) is what shows first.
                DisclosureGroup(isExpanded: $showRouteExtras) {
                    VStack(spacing: 12) {
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

                        // Avoid options (Pro, Google routing) — apply to Drive routes.
                        if transportMode == .drive {
                            Toggle(isOn: $avoidHighways) {
                                Label(L("route.avoid_highways", fallback: "Avoid highways"), systemImage: "road.lanes")
                                    .font(.subheadline)
                            }
                            .tint(Wander.brand)
                            Toggle(isOn: $avoidTolls) {
                                Label(L("route.avoid_tolls", fallback: "Avoid tolls"), systemImage: "dollarsign.circle")
                                    .font(.subheadline)
                            }
                            .tint(Wander.brand)
                            if avoidHighways || avoidTolls {
                                Text(localized: "route.avoid.footer",
                                     fallback: "Uses Google routing (Pro) to honor these — tap Preview.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        saveLoopControls

                        recordControls

                        aiRoutineControls
                    }
                    .padding(.top, 6)
                } label: {
                    Label(L("route.more_options", fallback: "More options — loop, weather, save, record, AI day"),
                          systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                }
                .tint(Wander.brand)

                HStack(spacing: 10) {
                    Button {
                        // Guard in the ACTION rather than via .disabled — a disabled bordered button
                        // renders a muted grey label that's invisible on the dark card in dark mode,
                        // so the boxes looked blank and users couldn't tell what they were.
                        if waypoints.count < 2 {
                            alertText = L("route.need_two_points", fallback: "Add at least 2 points to preview a route.")
                            return
                        }
                        Task { await computeRoute() }
                    } label: {
                        Label(L("route.preview", fallback: "Preview"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(Wander.brand)
                    .controlSize(.large)
                    .disabled(isComputing)

                    Button {
                        if routeCoordinates.count < 2 {
                            alertText = L("route.preview_first", fallback: "Tap Preview first to build the route, then Drive.")
                            return
                        }
                        Task { await startDrive() }
                    } label: {
                        Label(L("route.drive", fallback: "Drive"), systemImage: Wander.Icon.play)
                            .font(.headline)
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Wander.brand)
                    .controlSize(.large)
                    .disabled(isComputing)
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
        .hugScrollCard(maxHeight: UIScreen.main.bounds.height * 0.44)
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
        routeCoordinates = []; routeAlternatives = []
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
                routeCoordinates = []; routeAlternatives = []
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
        case .plane:   return L("route.mode.plane_hint", fallback: "Flies a great-circle path from the first to the last point — only for long trips (~100 km+). Altitude can't be simulated on iOS, so only the path and speed are applied.")
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
        routeCoordinates = []; routeAlternatives = []
        routeExpectedTime = 0
    }

    private func deleteWaypoints(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        routeCoordinates = []; routeAlternatives = []
        routeExpectedTime = 0
    }

    /// Flip the waypoint order (B→A→…) so a saved commute can be run in the
    /// opposite direction — work-to-home instead of home-to-work. Invalidates the
    /// previewed path so the next Preview/Drive re-routes along the new order.
    private func reverseWaypoints() {
        guard waypoints.count >= 2 else { return }
        waypoints.reverse()
        routeCoordinates = []; routeAlternatives = []
        routeExpectedTime = 0
        if let region = region(fitting: waypoints.map(\.coordinate)) {
            cameraPosition = .region(region)
        }
    }

    private func clearAll() {
        waypoints = []
        routeCoordinates = []; routeAlternatives = []
        currentPosition = nil
    }

    /// Load a GPX / KML / GeoJSON / CSV file's coordinates as waypoints (parity with Android/desktop).
    private func handleRouteFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertText = "Couldn't open that file: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let coords = try RouteFileImporter.parse(data: data, filename: url.lastPathComponent)
                waypoints.append(contentsOf: coords.map { RouteWaypoint(coordinate: $0) })
                routeCoordinates = []; routeAlternatives = []
                if let region = region(fitting: waypoints.map(\.coordinate)) {
                    cameraPosition = .region(region)
                }
                alertText = "Imported \(coords.count) point\(coords.count == 1 ? "" : "s") from \(url.lastPathComponent)."
            } catch {
                alertText = (error as? LocalizedError)?.errorDescription ?? "Couldn't read that file."
            }
        }
    }

    // MARK: - Route computation

    private func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    /// Prominent "how long + how far" line, shown as soon as a route is previewed — for every mode
    /// with a known time/distance (drive & walk from Apple's ETA, transit from Google's). Before,
    /// the time only appeared inside the Realistic-mode hint, so Speed-limit / Manual users only saw
    /// it once the drive actually started.
    @ViewBuilder private var routeSummaryLine: some View {
        let v = routeSummaryValues()
        if v.eta > 0 || v.dist > 0 {
            HStack(spacing: 16) {
                if v.eta > 0 { Label(etaText(v.eta), systemImage: "clock.fill") }
                if v.dist > 0 { Label(distanceText(v.dist), systemImage: "arrow.triangle.turn.up.right.diamond.fill") }
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Wander.brand)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ETA + distance for the summary line: the selected alternative's numbers, or — for a single
    /// concatenated route (multi-stop trips that don't produce alternatives) — the route ETA and the
    /// measured path length.
    private func routeSummaryValues() -> (eta: TimeInterval, dist: Double) {
        if routeAlternatives.indices.contains(selectedRouteIndex) {
            return (routeAlternatives[selectedRouteIndex].expectedTime,
                    routeAlternatives[selectedRouteIndex].distanceMeters)
        } else if routeCoordinates.count > 1 {
            return (routeExpectedTime, pathDistanceMeters(routeCoordinates))
        }
        return (0, 0)
    }

    private func etaText(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded()))
        return mins < 60 ? "\(mins) min" : "\(mins / 60) h \(mins % 60) min"
    }

    private func distanceText(_ meters: Double) -> String {
        if useMph {
            let mi = meters / 1609.34
            return mi < 0.1 ? "\(Int(meters * 3.28084)) ft" : String(format: "%.1f mi", mi)
        }
        return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
    }

    private func pathDistanceMeters(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count {
            total += CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
        }
        return total
    }

    /// Transit journey breakdown — one row per leg (walk / bus / train / ferry …) with its mode
    /// icon, the line, and the time. Shown only for a transit route that returned steps, and
    /// reflects the currently-selected alternative so it matches the highlighted line on the map.
    @ViewBuilder private var transitBreakdown: some View {
        let steps = routeAlternatives.indices.contains(selectedRouteIndex)
            ? routeAlternatives[selectedRouteIndex].steps : []
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("route.journey", fallback: "Journey"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(steps) { step in
                    HStack(spacing: 10) {
                        Image(systemName: transitIcon(step))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(step.mode == "WALK" ? Color.secondary : Wander.brand)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(transitTitle(step)).font(.footnote.weight(.medium))
                            let sub = transitSubtitle(step)
                            if !sub.isEmpty {
                                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if step.durationSeconds > 0 {
                            Text("\(max(1, Int((step.durationSeconds / 60).rounded()))) min")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transitIcon(_ s: WanderDirections.RouteStep) -> String {
        if s.mode == "WALK" { return "figure.walk" }
        switch s.vehicle.uppercased() {
        case "BUS", "INTERCITY_BUS", "TROLLEYBUS": return "bus.fill"
        case "FERRY": return "ferry.fill"
        default: return "tram.fill"   // subway / metro / heavy-rail / tram / light-rail / …
        }
    }

    private func transitTitle(_ s: WanderDirections.RouteStep) -> String {
        if s.mode == "WALK" { return L("route.walk", fallback: "Walk") }
        let kind: String
        switch s.vehicle.uppercased() {
        case "BUS", "INTERCITY_BUS", "TROLLEYBUS": kind = "Bus"
        case "SUBWAY", "METRO_RAIL": kind = "Subway"
        case "HEAVY_RAIL", "RAIL", "COMMUTER_TRAIN", "HIGH_SPEED_TRAIN", "LONG_DISTANCE_TRAIN": kind = "Train"
        case "TRAM", "LIGHT_RAIL": kind = "Tram"
        case "FERRY": kind = "Ferry"
        case "CABLE_CAR", "GONDOLA_LIFT": kind = "Cable car"
        case "MONORAIL": kind = "Monorail"
        default: kind = s.vehicle.isEmpty ? "Transit" : s.vehicle.capitalized
        }
        return s.line.isEmpty ? kind : "\(kind) \(s.line)"
    }

    private func transitSubtitle(_ s: WanderDirections.RouteStep) -> String {
        if s.mode == "WALK" {
            guard s.distanceMeters > 0 else { return "" }
            return s.distanceMeters >= 1000
                ? String(format: "%.1f km", s.distanceMeters / 1000)
                : "\(Int(s.distanceMeters)) m"
        }
        if !s.headsign.isEmpty { return "toward \(s.headsign)" }
        if !s.from.isEmpty && !s.to.isEmpty { return "\(s.from) → \(s.to)" }
        if s.stops > 0 { return "\(s.stops) stop\(s.stops == 1 ? "" : "s")" }
        return ""
    }

    private func computeRoute() async {
        guard waypoints.count >= 2 else { return }
        isComputing = true
        routeNotice = nil
        routeAlternatives = []
        selectedRouteIndex = 0
        defer { isComputing = false }

        // PLANE flies a great-circle track (no road snapping). Only draw a route for a trip long
        // enough to actually fly — otherwise say "no route available" instead of a fake line.
        if !transportMode.usesRoadRouting {
            let first = waypoints.first!.coordinate
            let last = waypoints.last!.coordinate
            let km = CLLocation(latitude: first.latitude, longitude: first.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) / 1000
            if km < 100 {
                routeCoordinates = []; routeAlternatives = []
                routeExpectedTime = 0
                routeNotice = "No route available — \(Int(km)) km is too short to fly. Plane trips need ~100 km+."
                return
            }
            let coords = greatCircleCoordinates()
            routeCoordinates = coords
            routeExpectedTime = 0
            if let region = region(fitting: coords) {
                cameraPosition = .region(region)
            }
            return
        }

        // GOOGLE (Pro) path — the routing Apple can't do (real cycling, combined transit) or when
        // avoid-highways/tolls is set. Basic Drive/Walk (no avoid) stay on Apple MKDirections below.
        let needsGoogle = transportMode == .cycle || transportMode == .transit
            || (transportMode == .drive && (avoidHighways || avoidTolls))
        if needsGoogle {
            if !License.shared.isLicensed {
                routeCoordinates = []; routeAlternatives = []
                routeNotice = "Real cycling, transit and avoid-highways/tolls are a Pro feature."
                showPaywall = true
                return
            }
            let modeStr: String
            switch transportMode {
            case .cycle:   modeStr = "bicycling"
            case .transit: modeStr = "transit"
            case .walk:    modeStr = "walking"
            default:       modeStr = "driving"
            }
            let inter = waypoints.count > 2
                ? Array(waypoints[1..<(waypoints.count - 1)]).map(\.coordinate) : []
            let res = await WanderDirections.fetch(
                origin: waypoints.first!.coordinate,
                destination: waypoints.last!.coordinate,
                waypoints: inter,
                mode: modeStr,
                avoidHighways: avoidHighways,
                avoidTolls: avoidTolls,
                alternatives: inter.isEmpty   // 2–3 options only for point-to-point trips
            )
            switch res {
            case .success(let routes):
                let opts = routes
                    .filter { $0.points.count >= 2 }
                    .map { RouteOption(coordinates: $0.points,
                                       expectedTime: $0.durationSeconds,
                                       distanceMeters: $0.distanceMeters,
                                       label: $0.summary,
                                       steps: $0.steps) }
                if opts.isEmpty {
                    routeCoordinates = []; routeAlternatives = []; routeNotice = "No route available for this trip."
                } else {
                    applyAlternatives(opts)
                }
            case .noRoute:
                routeCoordinates = []; routeAlternatives = []; routeNotice = "No route available for this trip."
            case .proRequired:
                routeCoordinates = []; routeAlternatives = []
                routeNotice = "Sign in with your Pro account to use cycling/transit routing."
                showPaywall = true
            case .failed(let msg):
                routeCoordinates = []; routeAlternatives = []; routeNotice = msg
            }
            return
        }

        // Point-to-point (start + end): ask Apple for alternate routes so the user gets
        // 2–3 options to choose from, like Google Maps. Intermediate stops fall through to
        // the single concatenated route below (alternates don't combine with waypoints).
        if waypoints.count == 2 {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[0].coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[1].coordinate))
            request.transportType = transportMode.mapKitTransportType
            request.requestsAlternateRoutes = true
            if let response = try? await MKDirections(request: request).calculate(), !response.routes.isEmpty {
                let pacesToEta = (transportMode == .drive || transportMode == .walk)
                let opts = response.routes.prefix(3).map { r in
                    RouteOption(coordinates: coordinates(from: r.polyline),
                                expectedTime: pacesToEta ? r.expectedTravelTime : 0,
                                distanceMeters: r.distance,
                                label: r.name)
                }
                applyAlternatives(Array(opts))
                return
            }
            // MKDirections failed → fall through to the straight-line fallback below.
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

    // MARK: - Route options (2–3 alternatives)

    /// Store the computed options, select the fastest (index 0), and frame all of them so the
    /// user can compare. `routeCoordinates`/`routeExpectedTime` mirror the selected option, so
    /// Preview/Drive keep using them unchanged.
    private func applyAlternatives(_ opts: [RouteOption]) {
        routeAlternatives = opts
        selectedRouteIndex = 0
        guard let first = opts.first else { routeCoordinates = []; routeAlternatives = []; return }
        routeCoordinates = first.coordinates
        routeExpectedTime = first.expectedTime
        let all = opts.flatMap { $0.coordinates }
        if let region = region(fitting: all) { cameraPosition = .region(region) }
    }

    /// Pick a different option — swap the active path + ETA so Preview/Drive use it.
    private func selectRoute(_ i: Int) {
        guard routeAlternatives.indices.contains(i) else { return }
        selectedRouteIndex = i
        let opt = routeAlternatives[i]
        routeCoordinates = opt.coordinates
        routeExpectedTime = opt.expectedTime
    }

    /// The selectable list of 2–3 route options (shown only when more than one exists).
    @ViewBuilder private var routeOptionsPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized: "route.options", fallback: "Routes")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(routeAlternatives.enumerated()), id: \.element.id) { idx, opt in
                Button { selectRoute(idx) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: idx == selectedRouteIndex ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(idx == selectedRouteIndex ? Wander.brand : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(routeOptionPrimary(idx: idx, opt: opt))
                                    .font(.subheadline.weight(idx == selectedRouteIndex ? .semibold : .regular))
                                if idx == 0 && routeAlternatives.count > 1 {
                                    Text(L("route.fastest", fallback: "Fastest"))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Wander.brand.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Wander.brand)
                                }
                            }
                            if !opt.label.isEmpty {
                                Text(opt.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(routeDistanceLabel(opt.distanceMeters))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                if idx < routeAlternatives.count - 1 { Divider() }
            }
        }
    }

    /// Primary label for an option: the ETA when known ("23 min"), else "Route N".
    private func routeOptionPrimary(idx: Int, opt: RouteOption) -> String {
        if opt.expectedTime > 0 {
            let mins = Int((opt.expectedTime / 60).rounded())
            return mins >= 60
                ? String(format: "%dh %dm", mins / 60, mins % 60)
                : "\(max(mins, 1)) min"
        }
        return String(format: L("route.option_n", fallback: "Route %d"), idx + 1)
    }

    /// Distance formatted in the user's unit (mi/km) for the trailing metric.
    private func routeDistanceLabel(_ meters: Double) -> String {
        guard meters > 0 else { return "" }
        if useMph {
            let miles = meters / 1609.34
            return miles < 0.1 ? String(format: "%.0f ft", meters * 3.28084) : String(format: "%.1f mi", miles)
        } else {
            return meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.1f km", meters / 1000)
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

        // Only PLANE uses a great-circle track now (first waypoint → last waypoint).
        guard transportMode == .plane,
              let first = waypoints.first?.coordinate,
              let last = waypoints.last?.coordinate else { return [] }
        return greatCirclePath(from: first, to: last, steps: stepsFor(first, last))
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
        // We own the location stream for the whole drive: silence the Map tab's teleport "hold"
        // resend so it can't re-inject a stale prior-teleport point every 4 s and rubber-band us
        // backward mid-route — the impossible backward jump that trips PoGo "Failed to detect
        // location (12)". Re-asserted each step in the playback loop (see below); handed back on
        // completion. Mirrors WalkModeView / MapSelectionView route playback / ItineraryRunner.
        LocationSimulationCommandQueue.suppressResends = true
        // Moving writer now — stand the stationary-teleport snap-back watcher down so the drive
        // moving away from the teleport target can't false-fire its re-teleport (a second writer).
        SimulationSession.shared.movementModeDidBecomeActiveWriter()
        // Adventure Sync: open a fresh walk window for this drive (no-op unless
        // opted in). Per-sample deltas below feed the incremental Health writer.
        AdventureSyncManager.shared.beginWalk()
        if !License.shared.isLicensed { TrialManager.shared.chargeRoute() }

        let totalPlanned = samples.reduce(0) { $0 + $1.delayFromPrevious }
        let shouldLoop = loopRoute
        // HARD speed clamp for playback (see SpeedGovernor). Scoped to an active game context only:
        // capped at the game's community-cited safe speed when the user is framing movement around a
        // location game, and OFF otherwise so a general highway-drive / PLANE flight isn't throttled.
        let clampPreset: GamePreset? = gameSpeedWarn ? gamePreset : nil
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
                        var scaled = sample.delayFromPrevious / max(playbackRate, 0.1)
                        // Enforce the hard ceiling on the ACTUAL (post-playbackRate) step speed: if
                        // this sample's distance over `scaled` seconds would exceed the ceiling, stretch
                        // the sleep so the effective advance rate is held at the cap. Guards against a
                        // fast route sample (or a 4× rate) implying an impossible, ban-triggering jump.
                        if let clampPreset, index > 0 {
                            let stepMeters = CLLocation(latitude: samples[index - 1].coordinate.latitude,
                                                        longitude: samples[index - 1].coordinate.longitude)
                                .distance(from: CLLocation(latitude: sample.coordinate.latitude,
                                                           longitude: sample.coordinate.longitude))
                            let minDelay = stepMeters / SpeedGovernor.hardCeilingMps(for: clampPreset)
                            if minDelay > scaled { scaled = minDelay }
                        }
                        try? await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
                    }
                    if Task.isCancelled { break }
                    elapsed += sample.delayFromPrevious
                    // "Hold perfectly still" disables jitter; otherwise honor the jitter toggle.
                    // With Realistic motion on, use the clustered receiver-error model instead of
                    // the flat ±box drift so route fixes scatter like a real GPS.
                    let frozen = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
                    let outgoing = (!frozen && jitterEnabled)
                        ? (MotionRealism.isEnabled ? HumanizedMotion.gpsNoise(sample.coordinate) : LocationJitter.apply(sample.coordinate))
                        : sample.coordinate
                    // Re-assert single-writer ownership each step (mirrors WalkModeView.step()): nothing
                    // (e.g. a cross-tab teleport, or an auto-walk arrival posting .holdLocationRequested)
                    // may silently re-enable the map resend and rubber-band us backward mid-drive.
                    LocationSimulationCommandQueue.suppressResends = true
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
            if !Task.isCancelled {
                isDriving = false
                // Drive finished naturally — park at the destination. Hand the warm-hold back to the
                // Map tab's resend, re-seeded at the ARRIVED point, so the fix stays alive now that our
                // playback loop has stopped (mirrors WalkModeView.arriveAutoWalk). A user Stop instead
                // goes through stopAll() (clears + suppresses), so this only runs on natural completion.
                if let end = samples.last?.coordinate {
                    NotificationCenter.default.post(
                        name: .holdLocationRequested, object: nil,
                        userInfo: ["lat": end.latitude, "lng": end.longitude]
                    )
                }
            }
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
        routeCoordinates = []; routeAlternatives = []
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
        routeCoordinates = []; routeAlternatives = []
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
                .submitLabel(.done)
                .disabled(isGeneratingAI)
                .focused($aiFieldFocused)
                .onSubmit { aiFieldFocused = false }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L("action.done", fallback: "Done")) { aiFieldFocused = false }
                    }
                }

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
        routeCoordinates = []; routeAlternatives = []
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
