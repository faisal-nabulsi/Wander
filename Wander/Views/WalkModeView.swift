//
//  WalkModeView.swift
//  Wander
//
//  Live "walk" mode: an on-screen joystick moves the simulated location in
//  real time. Direction comes from the stick angle, speed from how far it's
//  pushed. Each tick advances the coordinate and re-sends it through the same
//  DVT LocationSimulation engine the Map screen uses.
//

import SwiftUI
import MapKit
import CoreLocation

struct WalkModeView: View {
    private let tickInterval: TimeInterval = 0.5
    private let joystickRadius: CGFloat = 52

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var visibleCenter: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @StateObject private var currentLocation = CurrentLocation()

    @State private var speedMps: Double = 6_000.0 / 3_600.0   // default 6 km/h
    @AppStorage("useMph") private var useMph = false
    // Optional per-game speed nudge (OFF by default): warn — never clamp — if the joystick speed
    // exceeds the selected game's community-cited safe ceiling. Reads the same prefs as the Games tab.
    @AppStorage("gameSpeedWarn") private var gameSpeedWarn = false
    @AppStorage("pogoGamePreset") private var gamePresetRaw = GamePreset.pokemonGo.rawValue
    private var gamePreset: GamePreset { GamePreset(rawValue: gamePresetRaw) ?? .pokemonGo }
    @State private var knobOffset: CGSize = .zero
    @State private var isWalking = false
    @State private var moveTimer: Timer?
    @State private var showPaywall = false
    @State private var joyFraction: Double = 0

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mapLayer
                controls
            }
            .navigationTitle(L("joystick.title", fallback: "Joystick"))
            .alert(alertTitle, isPresented: $showAlert) {
                Button(L("action.ok", fallback: "OK"), role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onDisappear { stopTimer() }
            .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
            .onReceive(NotificationCenter.default.publisher(for: .stopSimulationRequested)) { _ in
                localReset()
            }
            .onAppear { currentLocation.request() }
            .onReceive(currentLocation.$coordinate.compactMap { $0 }) { c in
                if coordinate == nil && !isWalking {
                    cameraPosition = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2500, longitudinalMeters: 2500))
                }
            }
        }
    }

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            if let coordinate {
                Annotation("You", coordinate: coordinate) {
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
            if coordinate == nil { MapCrosshair() }
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        WanderCard {
            VStack(spacing: 14) {
                if coordinate == nil {
                    AddressSearchBar(placeholder: "Search a place to start") { coord, _ in
                        coordinate = coord
                        recenter(on: coord)
                    }
                    WanderPrimaryButton(title: "Set start point", icon: Wander.Icon.setHere) {
                        setStartToCenter()
                    }
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        joystick
                        VStack(spacing: 10) {
                            Text("\(Int(SpeedFormat.fromMps(speedMps, useMph: useMph))) \(SpeedFormat.unitLabel(useMph: useMph))")
                                .font(.title3.bold()).monospacedDigit()
                            HStack(spacing: 6) {
                                Button(L("joystick.walk", fallback: "Walk")) { speedMps = 6_000.0 / 3_600.0 }.buttonStyle(.bordered).font(.caption)
                                Button(L("joystick.run", fallback: "Run")) { speedMps = 12_000.0 / 3_600.0 }.buttonStyle(.bordered).font(.caption)
                                Button(L("joystick.drive", fallback: "Drive")) { speedMps = 50_000.0 / 3_600.0 }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                    Slider(
                        value: Binding(
                            get: { SpeedFormat.fromMps(speedMps, useMph: useMph) },
                            set: { speedMps = SpeedFormat.toMps($0, useMph: useMph) }
                        ),
                        in: SpeedFormat.sliderRange(useMph: useMph),
                        step: 1
                    )
                    if gameSpeedWarn, speedMps * 3.6 > Double(gamePreset.maxSafeSpeedKmh) {
                        Label("Above \(gamePreset.shortTitle)'s safe speed (~\(Int(SpeedFormat.fromMps(Double(gamePreset.maxSafeSpeedKmh) / 3.6, useMph: useMph))) \(SpeedFormat.unitLabel(useMph: useMph)))",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    WanderPrimaryButton(title: "Stop", icon: Wander.Icon.stop, role: .destructive) {
                        stop()
                    }
                }
            }
        }
    }

    private var joystick: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: (joystickRadius + 30) * 2, height: (joystickRadius + 30) * 2)
            Circle()
                .fill(isWalking ? Color.accentColor : Color.gray)
                .frame(width: 60, height: 60)
                .offset(knobOffset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            var v = value.translation
                            let dist = hypot(v.width, v.height)
                            if dist > joystickRadius {
                                let scale = joystickRadius / dist
                                v = CGSize(width: v.width * scale, height: v.height * scale)
                            }
                            knobOffset = v
                            if !isWalking { start() }
                        }
                        .onEnded { _ in
                            knobOffset = .zero
                        }
                )
        }
        .frame(width: (joystickRadius + 30) * 2, height: (joystickRadius + 30) * 2)
    }

    // MARK: - Start / stop

    private func setStartToCenter() {
        guard let center = visibleCenter else {
            alert("Pan the map", "Move the map so a location is centered, then try again.")
            return
        }
        coordinate = center
        recenter(on: center)
    }

    private func start() {
        guard let coordinate else { return }
        guard pairingFilePath() != nil else {
            alert("Pairing file required", "Import a pairing file in Settings before simulating location.")
            self.coordinate = nil
            return
        }
        if !License.shared.isLicensed && !TrialManager.shared.canUse(.joystick) {
            showPaywall = true
            return
        }
        isWalking = true
        SimulationSession.shared.started()
        // Adventure Sync: start a fresh walk window so the first tick isn't measured
        // against a stale coordinate from an earlier run (no-op unless opted in).
        AdventureSyncManager.shared.beginWalk()
        send(coordinate)
        startTimer()
    }

    private func stop() {
        // Global stop: clears the device location and broadcasts a reset.
        SimulationSession.shared.stopAll()
    }

    private func localReset() {
        stopTimer()
        // Adventure Sync: flush the tail of the walk and clear accumulation.
        AdventureSyncManager.shared.endWalk()
        isWalking = false
        knobOffset = .zero
        coordinate = nil          // back to "set a new start" state
    }

    // MARK: - Movement

    private func startTimer() {
        stopTimer()
        moveTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            step()
        }
    }

    private func stopTimer() {
        moveTimer?.invalidate()
        moveTimer = nil
    }

    private func step() {
        guard isWalking, var coord = coordinate else { return }
        let magnitude = min(hypot(knobOffset.width, knobOffset.height) / joystickRadius, 1)
        guard magnitude > 0.02 else { return }

        // Charge free-trial joystick time only while actually moving. Cut off at the cap.
        if !License.shared.isLicensed {
            joyFraction += tickInterval
            while joyFraction >= 1 { TrialManager.shared.addJoystickSeconds(1); joyFraction -= 1 }
            if !TrialManager.shared.canUse(.joystick) {
                stop()
                showPaywall = true
                return
            }
        }

        // Screen up (-y) is north; +x is east.
        let bearing = atan2(Double(knobOffset.width), Double(-knobOffset.height))
        let distance = speedMps * Double(magnitude) * tickInterval

        let metersPerDegLat = 111_320.0
        let dLat = (distance * cos(bearing)) / metersPerDegLat
        let lonScale = max(cos(coord.latitude * .pi / 180), 0.000001)
        let dLon = (distance * sin(bearing)) / (metersPerDegLat * lonScale)

        coord.latitude += dLat
        coord.longitude += dLon
        coordinate = coord
        recenter(on: coord)
        send(coord)
        // Adventure Sync: mirror this simulated step into Health (no-op unless opted
        // in). Derived from the ACTUAL per-tick movement, at a human cadence.
        AdventureSyncManager.shared.recordSimulatedMovement(to: coord)
    }

    private func recenter(on coord: CLLocationCoordinate2D) {
        cameraPosition = .camera(MapCamera(centerCoordinate: coord, distance: 1_200))
    }

    // MARK: - Engine

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    private func send(_ coord: CLLocationCoordinate2D) {
        guard let path = pairingFilePath() else { return }
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, coord.latitude, coord.longitude, path)
        }
    }

    private func alert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    WalkModeView()
}
