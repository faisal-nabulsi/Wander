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
    // PoGo (gs-loc) mode steers only NETWORK location and only holds a STATIC fix — the joystick, routes
    // and auto-walk silently fail there (iOS's real GPS overrides the moving injection and the avatar
    // snaps back home). So when this is on we disable live movement outright rather than let it fail
    // quietly. Bound to GslocMode's own defaults key so flipping the mode updates this instantly.
    @AppStorage(GslocMode.defaultsKey) private var gslocMode = false
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

    // MARK: Distance goal ("farm mode")
    //
    // Egg hatching and buddy candy pay out on DISTANCE, so "walk until N km, then stop" is what a
    // farming session is actually judged by. The counter is fed from the clean per-tick advance the
    // humanized engine really produced — not from the slider's nominal speed — so pace wobble and
    // micro-pauses are reflected honestly and our number matches what the game will credit.
    @State private var sessionMeters: Double = 0
    /// Goal progress is measured from wherever the session counter stood when the goal was picked,
    /// so choosing a goal mid-walk can't be instantly satisfied and slam movement to a stop.
    @State private var goalBaseMeters: Double = 0
    @State private var goalCompleted = false
    /// The goal is a preference, not session state: someone farming 10 km eggs wants the same goal
    /// still set tomorrow. Stored in metres so switching km/mi doesn't silently move the target.
    /// 0 ⇒ no goal.
    @AppStorage("walkGoalMeters") private var goalMeters: Double = 0
    // Daily bucket: one running total plus the local-date key it belongs to. Re-checking that key
    // is what makes the reset land at LOCAL midnight without a timer — a timer wouldn't survive the
    // app being killed, and a plain date comparison is also right after a timezone change.
    @AppStorage("walkDailyMeters") private var dailyMeters: Double = 0
    @AppStorage("walkDailyMetersDate") private var dailyMetersDate = ""
    /// Free-entry goal ("walk until N"), typed in whatever unit the user reads in.
    @State private var showCustomGoal = false
    @State private var customGoalText = ""

    // MARK: Heading lock (hands-free straight-line walking)
    //
    // Pins the direction so the user can put the phone down. Locked ⇒ the motion model runs in the
    // `.autonomous` context, i.e. MORE realism than steering (micro-pauses included): a locked
    // heading means "keep going this way", not "become a perfectly straight robot". A ruler-straight
    // trace at a dead-constant speed is the loudest spoof tell there is, so the lock must not buy
    // convenience by turning the realism layer off.
    @State private var lockedHeading: Double?
    /// Throttle (stick fraction) captured at lock time. Speed is recomputed as `speedMps × fraction`
    /// every tick rather than frozen, so the speed slider stays live while locked.
    @State private var lockedFraction: Double = 1
    /// Last direction/throttle the stick was pushed in. Kept because the knob springs back to centre
    /// on release, so without this "Lock heading" would have nothing to pin a moment later.
    @State private var lastStickBearing: Double?
    @State private var lastStickFraction: Double = 1

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
            .alert(L("joystick.goal.custom.title", fallback: "Stop at distance"), isPresented: $showCustomGoal) {
                TextField(useMph ? L("unit.miles", fallback: "Miles") : L("unit.km", fallback: "Kilometres"),
                          text: $customGoalText)
                    .keyboardType(.decimalPad)
                Button(L("joystick.goal.custom.set", fallback: "Set")) { commitCustomGoal() }
                Button(L("action.cancel", fallback: "Cancel"), role: .cancel) { }
            } message: {
                Text(L("joystick.goal.custom.body",
                       fallback: "Movement stops by itself once you've walked this far — the counter lands exactly on the number."))
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
                // Roll the daily bucket here too, not just while moving: opening the tab the morning
                // after a farm run must read "Today 0", not yesterday's total.
                rollDailyBucketIfNeeded()
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
                if gslocMode {
                    gslocTeleportOnlyNote
                }
                if cooldownNoteVisible {
                    cooldownNote
                }
                Group {
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
                    headingLockRow
                    farmSection
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
                // Teleport-only in gs-loc mode: dim and disable every live-movement control so a
                // silent "spawns at home" failure can't happen. Teleport itself lives on the Location
                // tab and stays fully usable.
                .disabled(gslocMode)
                .opacity(gslocMode ? 0.5 : 1)
            }
        }
    }

    /// Shown at the top of the Joystick controls while PoGo (gs-loc) mode is on: live movement doesn't
    /// work through the gs-loc network path, so the controls below are disabled and the user is pointed
    /// back to teleport (which is all gs-loc supports).
    private var gslocTeleportOnlyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(L("joystick.gsloc_teleport_only",
                   fallback: "PoGo mode is teleport-only. Joystick, routes & auto-walk work in every other app and mode."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Heading lock UI

    /// Lock / unlock control plus the locked-state readout. Deliberately a separate row from the
    /// joystick: while locked the knob sits centred (nobody's touching it), which on its own would
    /// read as "stopped" — the state has to be spelled out in words somewhere.
    private var headingLockRow: some View {
        HStack(spacing: 8) {
            if let locked = lockedHeading {
                Label(String(format: L("joystick.lock.active", fallback: "Heading locked — walking %@"),
                             compassLabel(locked)),
                      systemImage: "location.north.line.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Wander.brand)
                Spacer(minLength: 0)
                Button(L("joystick.lock.unlock", fallback: "Unlock")) { toggleHeadingLock() }
                    .buttonStyle(.borderedProminent)
                    .tint(Wander.brand)
                    .font(.caption)
            } else {
                Button {
                    toggleHeadingLock()
                } label: {
                    Label(L("joystick.lock.lock", fallback: "Lock heading"), systemImage: "location.north.line")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Text(L("joystick.lock.hint", fallback: "Push the stick, then lock to keep walking hands-free."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Distance / goal UI

    /// Live distance readout plus the "stop at N" goal picker. Session and today sit side by side
    /// because they answer different questions: how far this run has gone (is my egg close?) and
    /// how much the account has "walked" today (does this look like a plausible human day?).
    private var farmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(String(format: L("joystick.distance.session", fallback: "Session %@"),
                             distanceText(sessionMeters)),
                      systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(String(format: L("joystick.distance.today", fallback: "Today %@"),
                            distanceText(dailyMeters)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(L("joystick.goal.label", fallback: "Stop at"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The chips scroll: four egg tiers plus Custom and Off don't fit a phone's width in
                // miles ("6.21 mi" is a wide chip), and shrinking the labels to make them fit would
                // throw away the precision that's the whole reason we show the converted number.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(goalPresetsKm, id: \.self) { km in
                            let meters = km * 1000
                            Button(goalPresetTitle(km)) { setGoal(meters: meters) }
                                .buttonStyle(.bordered)
                                .tint(isGoalSelected(meters) ? Wander.brand : nil)
                                .font(.caption)
                        }
                        // Free entry, because "walk until N km" is the actual request — the presets
                        // are shortcuts for the common N, not the whole vocabulary (buddy candy and
                        // a half-finished egg both want numbers that aren't on the list).
                        Button(L("joystick.goal.custom", fallback: "Custom…")) { promptCustomGoal() }
                            .buttonStyle(.bordered)
                            .tint(goalMeters > 0 && !isPresetGoal ? Wander.brand : nil)
                            .font(.caption)
                        if goalMeters > 0 {
                            Button(L("joystick.goal.off", fallback: "Off")) { setGoal(meters: 0) }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if goalCompleted {
                Label(String(format: L("joystick.goal.reached",
                                       fallback: "Goal reached — %@ walked. Movement stopped; you're parked here."),
                             distanceText(goalMeters)),
                      systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if goalMeters > 0 {
                ProgressView(value: min(goalProgressMeters / goalMeters, 1))
                    .tint(Wander.brand)
                Text(goalProgressText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var joystick: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: (joystickRadius + 30) * 2, height: (joystickRadius + 30) * 2)
                .overlay(
                    Circle().strokeBorder(Wander.brand.opacity(lockedHeading == nil ? 0 : 0.9), lineWidth: 3)
                )
            if let locked = lockedHeading {
                // A marker on the rim pointing the way we're walking. Rotating a full-size, top-
                // aligned frame (rather than offsetting the glyph) keeps the pivot at the pad's
                // centre, so the arrow tracks the bearing instead of orbiting its own middle.
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.caption)
                    .foregroundStyle(Wander.brand)
                    .frame(width: (joystickRadius + 30) * 2, height: (joystickRadius + 30) * 2, alignment: .top)
                    .rotationEffect(.radians(locked))
            }
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
                            // Remember the push HERE, not in step(): the tick only samples at 1 Hz,
                            // so any flick shorter than a second — exactly what "push the stick,
                            // then lock" invites — would never be seen, and Lock heading would
                            // either refuse outright or silently pin a bearing from some earlier
                            // steer. Same 0.02 dead zone step() uses, so the two agree on what
                            // counts as a push. Screen up (-y) is north; +x is east.
                            let mag = min(hypot(v.width, v.height) / joystickRadius, 1)
                            if mag > 0.02 {
                                lastStickBearing = atan2(Double(v.width), Double(-v.height))
                                lastStickFraction = Double(mag)
                            }
                            // Taking the stick cancels a hands-free walk and returns to steering.
                            if autoWalkTarget != nil {
                                autoWalkTarget = nil
                                motion = HumanizedMotion(context: .steered)
                            }
                            // Same idiom for the heading lock: a hand back on the stick means the
                            // user is steering again, so the pin gets out of the way rather than
                            // fighting the input.
                            releaseHeadingLock(resetGait: true)
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
        beginDistanceSession()
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
        lockedHeading = nil
        lastStickBearing = nil
        knobOffset = .zero
        coordinate = nil          // back to "set a new start" state
        // Session counters belong to the run that just ended; the daily total deliberately survives
        // (that's the whole point of it) and is already persisted tick by tick.
        sessionMeters = 0
        goalBaseMeters = 0
        goalCompleted = false
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
            if magnitude > 0.02 {
                idleTicks = 0
                // Screen up (-y) is north; +x is east.
                baseBearing = atan2(Double(knobOffset.width), Double(-knobOffset.height))
                targetSpeed = speedMps * Double(magnitude)
                // (The drag gesture — not this tick — records the push for "Lock heading"; at 1 Hz
                // we'd miss every short flick.)
            } else if let locked = lockedHeading {
                // Hands-free: keep walking the pinned heading. Speed is re-derived from the LIVE
                // slider each tick instead of being frozen at lock time, so the user can still ease
                // the pace up or down without having to unlock and re-aim.
                idleTicks = 0
                baseBearing = locked
                targetSpeed = speedMps * lockedFraction
            } else {
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
        var distance = autoWalkTarget != nil ? min(cappedSpd * tickInterval, remaining) : cappedSpd * tickInterval
        // Distance goal: shorten the LAST step so we land on the number instead of sailing past it.
        // "Stop at 5 km" has to actually read 5.00 km, because the first thing a farmer does is
        // compare our counter against the game's. This trims a step, never a speed — the speed
        // guardrail above stays the only thing allowed to touch pace.
        let goalRemaining = goalMeters > 0
            ? max(goalMeters - goalProgressMeters, 0)
            : Double.greatestFiniteMagnitude
        let goalHit = distance >= goalRemaining
        if goalHit { distance = goalRemaining }

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
        // trigger), so send the clean point for small steps. A goal-completing step is also sent
        // clean: we park on it, and the hold we hand back re-asserts this exact coordinate — a
        // scattered final fix would leave the parked point 2 m off the one we counted.
        let reported = (MotionRealism.isEnabled && distance > 2.5 && !goalHit) ? HumanizedMotion.gpsNoise(coord) : coord
        send(reported)
        // Adventure Sync: mirror this simulated step into Health (no-op unless opted
        // in). Derived from the ACTUAL per-tick movement, at a human cadence.
        AdventureSyncManager.shared.recordSimulatedMovement(to: coord)
        // Count what we actually moved, then land the goal if this was the step that finished it.
        accumulateDistance(distance)
        if goalHit { completeDistanceGoal() }
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
        beginDistanceSession()
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

    // MARK: - Distance goal (farm mode)

    /// Distance still owed on the current goal, measured from where the counter stood when the goal
    /// was picked (see `goalBaseMeters`).
    private var goalProgressMeters: Double { max(sessionMeters - goalBaseMeters, 0) }

    /// A fresh run starts a fresh session counter and clears any previous "goal reached" banner —
    /// otherwise the leftover total would satisfy the goal again on the very first tick. The daily
    /// bucket is deliberately untouched.
    private func beginDistanceSession() {
        sessionMeters = 0
        goalBaseMeters = 0
        goalCompleted = false
        rollDailyBucketIfNeeded()
    }

    /// Fold this tick's real advance into the session and daily totals. Called with the distance we
    /// actually applied to the coordinate, so a humanized micro-pause honestly contributes nothing.
    private func accumulateDistance(_ meters: Double) {
        guard meters > 0 else { return }
        sessionMeters += meters
        rollDailyBucketIfNeeded()
        dailyMeters += meters
    }

    /// Zero the daily bucket when the local calendar date has changed. Checked on every accumulate
    /// (and on appear) rather than scheduled, so it's correct whether the app was killed overnight
    /// or left running straight through midnight.
    private func rollDailyBucketIfNeeded() {
        let key = todayKey
        guard dailyMetersDate != key else { return }
        dailyMetersDate = key
        dailyMeters = 0
    }

    /// Local-date key, built from calendar components rather than a `DateFormatter` so it's cheap
    /// enough to recompute every tick and can't drift with the device's locale or calendar display
    /// settings.
    private var todayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Set (or clear, with 0) the goal. Rebasing on the live session counter is what lets someone
    /// raise the goal mid-run — "another 5 km from here" — instead of the new target being counted
    /// as already met.
    private func setGoal(meters: Double) {
        goalMeters = meters
        goalBaseMeters = sessionMeters
        goalCompleted = false
        Haptics.selection()
    }

    /// The goal was reached on this tick: stop moving but STAY here. This is the auto-walk arrival
    /// landing (settle, hand the warm-hold back to the Map tab's resend), not the red Stop button's
    /// teardown — the whole point of farming to a spot is that you keep the spot.
    private func completeDistanceGoal() {
        AdventureSyncManager.shared.endWalk()
        autoWalkTarget = nil
        releaseHeadingLock(resetGait: false)
        isWalking = false
        knobOffset = .zero
        idleTicks = 0
        goalCompleted = true
        stopTimer()
        Haptics.medium()
        if let c = coordinate {
            NotificationCenter.default.post(
                name: .holdLocationRequested, object: nil,
                userInfo: ["lat": c.latitude, "lng": c.longitude]
            )
        }
    }

    /// The presets are the game's egg tiers, in KILOMETRES, whatever unit the user reads in. These
    /// aren't "round numbers" we're free to re-round per locale — 2/5/7/10 km are thresholds the
    /// game itself defines, and a mile-preference player farms exactly the same ones. Rounding them
    /// into miles is how you end up offering "3 mi" (4.83 km), which leaves a 5 km egg unhatched at
    /// the moment we stop. So only the LABEL converts; the goal is stored in metres either way.
    private let goalPresetsKm: [Double] = [2, 5, 7, 10]
    private func goalPresetTitle(_ km: Double) -> String {
        useMph ? String(format: "%.2f mi", km * 1000 / 1609.34) : "\(Int(km)) km"
    }
    /// Tolerant compare: the stored goal is metres, so a typed mile value never round-trips exactly.
    private func isGoalSelected(_ meters: Double) -> Bool { abs(goalMeters - meters) < 1 }
    /// True when the live goal is one of the chips — used to highlight "Custom…" when it ISN'T, so a
    /// hand-typed 3.4 km goal still shows up as selected somewhere instead of looking unset.
    private var isPresetGoal: Bool { goalPresetsKm.contains { isGoalSelected($0 * 1000) } }

    /// Metres in one unit of whatever the user reads in — the single place the mile constant lives
    /// on the goal path, so entry, display and the chip labels can't drift apart.
    private var metersPerDisplayUnit: Double { useMph ? 1609.34 : 1000 }

    /// Progress reads "1.20 / 5.00 km": ONE unit for the pair, taken from the goal side. Formatting
    /// each half with `distanceText` labels them independently, so a part-walked goal came out as
    /// "340 m / 5.00 km" — two units inside one fraction, which takes a beat to read mid-walk.
    private var goalProgressText: String {
        String(format: "%.2f / %.2f %@",
               goalProgressMeters / metersPerDisplayUnit,
               goalMeters / metersPerDisplayUnit,
               useMph ? "mi" : "km")
    }

    /// Open the free-entry prompt, seeded with the current goal so "5 km — actually, make it 6" is
    /// an edit rather than a re-type.
    private func promptCustomGoal() {
        customGoalText = goalMeters > 0
            ? String(format: "%.2f", goalMeters / metersPerDisplayUnit)
            : ""
        showCustomGoal = true
    }

    /// Apply the typed distance, read in the user's display unit and stored as metres. Comma is
    /// accepted as the decimal separator because that's what sits under the thumb on a German or
    /// French keyboard and `Double("2,5")` is nil. Anything unparseable re-opens the prompt with the
    /// text intact instead of silently doing nothing — the alert has to be re-presented on a later
    /// runloop turn, because SwiftUI is still tearing the first one down when this button fires.
    private func commitCustomGoal() {
        let raw = customGoalText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(raw), value > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showCustomGoal = true }
            return
        }
        // Ceiling at 100 km: a fat-fingered extra zero would arm a goal no session can finish, which
        // is indistinguishable, from the user's side, from the goal being ignored entirely.
        setGoal(meters: min(value * metersPerDisplayUnit, 100_000))
    }

    /// Distance in the user's unit, mirroring RouteModeView's phrasing so a walked kilometre reads
    /// the same everywhere. Two decimals (rather than the route screen's one) because egg progress
    /// is judged in tens of metres.
    private func distanceText(_ meters: Double) -> String {
        if useMph {
            let miles = meters / 1609.34
            return miles < 0.1 ? "\(Int(meters * 3.28084)) ft" : String(format: "%.2f mi", miles)
        }
        return meters >= 1000 ? String(format: "%.2f km", meters / 1000) : "\(Int(meters)) m"
    }

    // MARK: - Heading lock

    /// Pin (or release) the current direction so the phone can go in a pocket. The heading comes
    /// from the stick if it's being held, otherwise from the last direction it was pushed — tapping
    /// Lock a beat after letting go is the natural gesture, and by then the knob has re-centred.
    private func toggleHeadingLock() {
        if lockedHeading != nil {
            releaseHeadingLock(resetGait: true)
            Haptics.light()
            return
        }
        let live = min(hypot(knobOffset.width, knobOffset.height) / joystickRadius, 1)
        let bearing: Double
        let fraction: Double
        if live > 0.02 {
            bearing = atan2(Double(knobOffset.width), Double(-knobOffset.height))
            fraction = Double(live)
        } else if let target = autoWalkTarget, let here = coordinate {
            // Locking mid auto-walk: the course being walked IS the direction the user means, and
            // the knob is centred by design (startAutoWalk zeroes it). Falling through to the stick
            // history here would be wrong twice over — it would either refuse ("pick a direction")
            // while the avatar is visibly walking a well-defined line, or pin a stale bearing from
            // an earlier steer and quietly veer off the trip the user was watching. Full throttle,
            // because that's the pace auto-walk was already holding.
            bearing = bearingRad(from: here, to: target)
            fraction = 1
        } else if let last = lastStickBearing {
            bearing = last
            fraction = lastStickFraction
        } else {
            alert(L("joystick.lock.need_heading.title", fallback: "Pick a direction first"),
                  L("joystick.lock.need_heading.body",
                    fallback: "Push the joystick the way you want to walk, then tap Lock heading to keep going hands-free."))
            return
        }
        // start() owns the licence gate, the pairing-file check and taking over the location stream.
        // If it bails we must not leave a lock armed with nothing driving it.
        if !isWalking {
            start()
            guard isWalking else { return }
        }
        lockedHeading = bearing
        lockedFraction = max(fraction, 0.05)   // a barely-nudged stick shouldn't lock in a crawl
        // One hands-free mode at a time. When we got here from a live auto-walk this is a hand-off,
        // not a cancellation: the lock carries on along the exact course the trip was walking, so
        // the avatar keeps going in a straight line — it just no longer stops at the destination.
        autoWalkTarget = nil
        // Set the gait AFTER start(), which seeds a steered one. Hands-free ⇒ `.autonomous`: the
        // full realism package, micro-pauses included. Locking the heading must not also lock out
        // the wobble — a perfectly straight, perfectly paced line is exactly what gets flagged.
        motion = HumanizedMotion(context: .autonomous)
        Haptics.medium()
    }

    /// Drop the lock. `resetGait` re-seeds the motion model in the steered context — the user's hand
    /// is back on the stick, so we want the responsive gait that never comes to a full stop.
    private func releaseHeadingLock(resetGait: Bool) {
        guard lockedHeading != nil else { return }
        lockedHeading = nil
        if resetGait { motion = HumanizedMotion(context: .steered) }
    }

    /// Compass point for the locked bearing (0 = north, clockwise), so the locked state says
    /// "walking NE" instead of showing the user a number in radians.
    private func compassLabel(_ radians: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        var degrees = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return names[Int((degrees / 45).rounded()) % 8]
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
        // gs-loc mode injects through the proxy, not the dev tunnel — no pairing file needed, so return
        // the path even when none is imported (the FFI short-circuits to the proxy before using it).
        return (FileManager.default.fileExists(atPath: url.path) || GslocMode.enabled) ? url.path : nil
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
