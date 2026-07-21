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
    // 1 Hz: matches a real GPS receiver's fix cadence and halves how many location injects hit the
    // serial tunnel queue per second. Fewer, larger, smoothly-advancing steps read more like a real
    // phone than a 2 Hz stream and give PoGo less to reject (the belt to the resend-suppression fix
    // for "Failed to detect location (12)"). Ground speed is unchanged — distance scales with dt.
    private let tickInterval: TimeInterval = 1.0
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
    // Humanizes the raw stick input: subtle pace variation + a gently-wandering heading so the
    // walk isn't a ruler-straight line at a dead-constant speed. Steered ⇒ never a full stop.
    @State private var motion = HumanizedMotion(context: .steered)
    // Hands-free destination: when set, the avatar walks itself here (autonomous ⇒ full realism,
    // incl. micro-pauses) until it arrives. Grabbing the joystick cancels it.
    @State private var autoWalkTarget: CLLocationCoordinate2D?
    // Slow keep-alive counter for when the stick is centered mid-walk. Because we suppress the Map
    // tab's teleport resend for the whole walk (so it can't re-inject the old teleport point and
    // rubber-band us backward → PoGo Error 12), WE must re-assert the current point every few
    // seconds during a pause, or iOS drops the spoof.
    @State private var idleTicks = 0
    private var idleResendEveryTicks: Int { max(1, Int(4.0 / tickInterval)) }

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    // Cooldown-aware advisory: a non-blocking note shown briefly if the user starts moving while a
    // soft-ban cooldown is still running. Advisory only — it NEVER blocks or delays movement.
    @ObservedObject private var session = SimulationSession.shared
    @State private var cooldownNoteVisible = false
    @State private var cooldownNoteHideWork: DispatchWorkItem?

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
            .onDisappear {
                stopTimer()
                // Leaving the tab mid-walk stops our tick — which is also the only thing keeping the
                // fix warm while the map resend is suppressed. Hand the hold to the Map tab's resend at
                // the current point so the spoof doesn't decay off-screen. onAppear re-takes ownership.
                if isWalking, let c = coordinate {
                    NotificationCenter.default.post(
                        name: .holdLocationRequested, object: nil,
                        userInfo: ["lat": c.latitude, "lng": c.longitude]
                    )
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
            .onReceive(NotificationCenter.default.publisher(for: .stopSimulationRequested)) { _ in
                localReset()
            }
            .onAppear {
                currentLocation.request()
                // Returning to an in-progress walk: restart our tick so we re-take ownership
                // (step() re-asserts suppressResends) and resume keeping the fix warm — otherwise the
                // stopped timer would leave the joystick dead until the user hit Stop and restarted.
                if isWalking { startTimer() }
            }
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
                if cooldownNoteVisible {
                    cooldownNote
                }
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
                    // Hands-free auto-walk: pick a place and Wander walks there itself at the set
                    // speed, using realistic motion. Grab the joystick anytime to take over.
                    if autoWalkTarget != nil {
                        Label(L("joystick.autowalk.active", fallback: "Auto-walking to your destination…"),
                              systemImage: "figure.walk.motion")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        AddressSearchBar(placeholder: L("joystick.autowalk.search", fallback: "Auto-walk to a place…")) { coord, _ in
                            startAutoWalk(to: coord)
                        }
                    }
                    WanderPrimaryButton(title: "Stop", icon: Wander.Icon.stop, role: .destructive) {
                        stop()
                    }
                }
            }
        }
    }

    /// Non-blocking advisory shown when movement starts during a live cooldown. Reads the live
    /// remaining time so the MM:SS stays current while the note is up. Advisory only — never blocks.
    private var cooldownNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(String(
                format: L("joystick.cooldown_note",
                          fallback: "Heads up — moving still counts as interacting; your soft-ban cooldown is still running (%@)."),
                cooldownClock(session.cooldownRemaining)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    /// Show the cooldown-aware note (once, briefly) IF a cooldown is currently running. Called from
    /// both start() and startAutoWalk(). Non-blocking: it never gates or delays the movement start.
    private func noteCooldownIfActive() {
        guard session.cooldownActive, session.cooldownRemaining > 0 else { return }
        cooldownNoteHideWork?.cancel()
        withAnimation { cooldownNoteVisible = true }
        let work = DispatchWorkItem { withAnimation { cooldownNoteVisible = false } }
        cooldownNoteHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func cooldownClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
                            // Taking the stick cancels a hands-free walk and returns to steering.
                            if autoWalkTarget != nil {
                                autoWalkTarget = nil
                                motion = HumanizedMotion(context: .steered)
                            }
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
        // Advisory only (never blocks): if a soft-ban cooldown is still running, remind the user that
        // moving still counts as interacting. Shown before we flip isWalking; movement proceeds either way.
        noteCooldownIfActive()
        isWalking = true
        // We are now the sole location writer. Silence the Map tab's teleport "hold" resend so it
        // can't re-inject the frozen teleport point every 4 s and snap us backward mid-walk — the
        // impossible backward jump is exactly what makes Pokémon GO throw "Failed to detect
        // location (12)". step() re-asserts this each tick; we hand the hold back on stop/arrival.
        LocationSimulationCommandQueue.suppressResends = true
        // We are the moving writer now — stand the stationary-teleport snap-back watcher down so a
        // legitimate walk away from the teleport target can't false-fire it (its "Re-teleport" would
        // re-assert the stale target as a second writer mid-walk → Error 12).
        SimulationSession.shared.movementModeDidBecomeActiveWriter()
        motion = HumanizedMotion(context: .steered)   // fresh gait for this run
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
        autoWalkTarget = nil
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
        // During a walk WE own the location stream. Re-assert suppression of the Map tab's teleport
        // resend every tick so nothing (e.g. a teleport on another tab) can silently re-enable it
        // and rubber-band us back to the old point — the cause of PoGo's "Failed to detect (12)".
        LocationSimulationCommandQueue.suppressResends = true

        // Pick this tick's intended heading + speed from whichever mode is active.
        let baseBearing: Double
        let targetSpeed: Double
        var remaining = Double.greatestFiniteMagnitude
        if let target = autoWalkTarget {
            remaining = distanceMeters(coord, target)
            if remaining < 3 { arriveAutoWalk(at: target); return }   // close enough → done
            baseBearing = bearingRad(from: coord, to: target)
            targetSpeed = speedMps                                    // set-speed, hands-free
        } else {
            let magnitude = min(hypot(knobOffset.width, knobOffset.height) / joystickRadius, 1)
            guard magnitude > 0.02 else {
                // Stick centered but still in walk mode. The resend is suppressed above, so keep the
                // CURRENT fix warm ourselves on a slow (~4 s) cadence — a rock-steady stationary
                // re-assert PoGo accepts, so a pause can't let iOS drop the spoof. No gpsNoise here:
                // a held point should not breathe.
                idleTicks += 1
                if idleTicks >= idleResendEveryTicks {
                    idleTicks = 0
                    send(coord)
                }
                return
            }
            idleTicks = 0
            // Screen up (-y) is north; +x is east.
            baseBearing = atan2(Double(knobOffset.width), Double(-knobOffset.height))
            targetSpeed = speedMps * Double(magnitude)
        }

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

        // Humanize: vary pace and let the heading wander a touch so the trace curves like a real
        // walk. Off ⇒ pass-through (dead-straight, dead-constant — the old behaviour). On the final
        // few metres of an auto-walk, straighten the heading so wander can't dither around the pin.
        let onFinalApproach = (autoWalkTarget != nil) && remaining < 12
        let (spd, wanderHeading) = motion.next(targetSpeed: targetSpeed, baseHeading: baseBearing,
                                               dt: tickInterval, allowPause: !onFinalApproach)
        let heading = onFinalApproach ? baseBearing : wanderHeading
        // HARD speed clamp (ALWAYS ON, not user-disableable): cap the per-tick advance so the
        // effective ground speed can never exceed a ban-triggering ceiling — even if the slider (or
        // the humanized pace variance) pushed it higher. Applies to both joystick and auto-walk. If
        // the user opted into a game context (gameSpeedWarn) we cap at THAT game's community-cited
        // safe speed; otherwise SpeedGovernor uses its absolute ~35 km/h fallback. Either way the cap
        // is applied every tick. The soft `gameSpeedWarn` above still fires as a nudge; this is the
        // safety net that can't be turned off.
        let clampPreset: GamePreset? = gameSpeedWarn ? gamePreset : nil
        let cappedSpd = SpeedGovernor.clampSpeedMps(spd, preset: clampPreset)
        let distance = autoWalkTarget != nil ? min(cappedSpd * tickInterval, remaining) : cappedSpd * tickInterval

        let metersPerDegLat = 111_320.0
        let dLat = (distance * cos(heading)) / metersPerDegLat
        let lonScale = max(cos(coord.latitude * .pi / 180), 0.000001)
        let dLon = (distance * sin(heading)) / (metersPerDegLat * lonScale)

        coord.latitude += dLat
        coord.longitude += dLon
        coordinate = coord            // clean humanized path: display + next-tick anchor
        recenter(on: coord)
        // Scatter only the REPORTED fix by a few metres of receiver error, so consecutive points
        // don't trace a perfect line. Keeps `coord` clean for the map + Health. Gated on the step
        // being LARGER than the noise radius: at a tiny nudge the ±2.5 m random scatter would
        // dominate a sub-metre step and read as jumpy, near-teleport motion (a second Error-12
        // trigger), so send the clean point for small steps.
        let reported = (MotionRealism.isEnabled && distance > 2.5) ? HumanizedMotion.gpsNoise(coord) : coord
        send(reported)
        // Adventure Sync: mirror this simulated step into Health (no-op unless opted
        // in). Derived from the ACTUAL per-tick movement, at a human cadence.
        AdventureSyncManager.shared.recordSimulatedMovement(to: coord)
    }

    // MARK: - Auto-walk (hands-free)

    /// Begin walking, by itself, from the current spot to `target`. Autonomous ⇒ the motion
    /// engine adds the occasional realistic micro-pause. Pro/trial-gated like the joystick.
    private func startAutoWalk(to target: CLLocationCoordinate2D) {
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
        // Advisory only (never blocks): remind about a running soft-ban cooldown before auto-walk begins.
        noteCooldownIfActive()
        autoWalkTarget = target
        knobOffset = .zero        // defensive: ensure step() takes the auto-walk path, not the stick
        isWalking = true
        // Own the stream: suppress the Map tab's stale teleport resend for the duration (see start()).
        LocationSimulationCommandQueue.suppressResends = true
        // Moving writer now — stand the stationary snap-back watcher down (see start()).
        SimulationSession.shared.movementModeDidBecomeActiveWriter()
        motion = HumanizedMotion(context: .autonomous)   // hands-free ⇒ full realism incl. micro-pauses
        SimulationSession.shared.started()
        AdventureSyncManager.shared.beginWalk()
        send(coordinate)
        startTimer()
    }

    /// Arrived at the auto-walk destination: settle on the exact point and idle (staying put),
    /// without tearing down the whole simulation the way the red Stop button does.
    private func arriveAutoWalk(at target: CLLocationCoordinate2D) {
        coordinate = target
        recenter(on: target)
        // Parked exactly on the destination — send the CLEAN point (no ±2.5 m gpsNoise scatter); a
        // held point must be rock-steady, and the resend re-seed below holds this same clean point.
        send(target)
        AdventureSyncManager.shared.recordSimulatedMovement(to: target)
        AdventureSyncManager.shared.endWalk()
        autoWalkTarget = nil
        isWalking = false
        idleTicks = 0
        stopTimer()
        // Park here: hand the warm-hold back to the Map tab's resend, re-seeded at THIS arrived
        // point (re-enables resends at the correct spot instead of the pre-walk teleport origin,
        // and keeps the fix alive now that our own tick loop has stopped).
        NotificationCenter.default.post(
            name: .holdLocationRequested, object: nil,
            userInfo: ["lat": target.latitude, "lng": target.longitude]
        )
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Planar bearing from `a` to `b` in the joystick's convention (0 = north, +east), so it
    /// feeds `dLat = d·cos(h)`, `dLon = d·sin(h)` directly.
    private func bearingRad(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let metersPerDegLat = 111_320.0
        let dNorth = (b.latitude - a.latitude) * metersPerDegLat
        let lonScale = max(cos(a.latitude * .pi / 180), 0.000001)
        let dEast = (b.longitude - a.longitude) * metersPerDegLat * lonScale
        return atan2(dEast, dNorth)
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
