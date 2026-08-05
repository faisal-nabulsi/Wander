//
//  WalkModeView.swift
//  Wander
//
//  Live "walk" mode: an on-screen joystick moves the simulated location in
//  real time. Direction comes from the stick angle, speed from how far it's
//  pushed. Each tick advances the coordinate and re-sends it through the same
//  DVT LocationSimulation engine the Map screen uses.
//
//  The hands-free patterns (auto-walk, Roam, Orbit) are NOT separate movement engines: they
//  only decide what heading the tick should aim at — exactly the job the stick does when a
//  hand is on it. Everything downstream (HumanizedMotion, the speed governor, the distance
//  counter, the single-writer suppression) is the one code path in `step()`.
//

import SwiftUI
import MapKit
import CoreLocation

/// A hands-free shape the avatar walks by itself, with no destination to arrive at.
///
/// Kept as one piece of state rather than a pile of independent flags because these are mutually
/// exclusive by nature — you cannot be roaming an area and orbiting a pin at the same time, and a
/// pair of booleans would let that contradiction exist.
private enum AutoPattern {
    /// Wander continuously INSIDE `radius` metres of `center`, turning back before the edge.
    case roam(center: CLLocationCoordinate2D, radius: Double)
    /// Walk laps around `center` at `radius` metres, optionally pausing `dwellSeconds` per lap.
    case orbit(center: CLLocationCoordinate2D, radius: Double, clockwise: Bool, dwellSeconds: Double)
}

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

    /// True while this view holds the background keep-alive.
    ///
    /// Without a hold, iOS suspends the app and reclaims the socket under the DVT connection (Apple
    /// TN2277), dropping the spoof — and on cellular the reconnect is refused by lockdownd, so it never
    /// comes back. This view had no keep-alive at all and survived only on the app-wide silent-audio one.
    ///
    /// A latch rather than raw requestStart/requestStop calls: there is one entry path but several exit
    /// paths, and unbalanced calls would decrement the shared activity count, possibly releasing a hold
    /// belonging to another active mode (e.g. a teleport hold running at the same time).
    @State private var keepAliveHeld = false

    private func holdKeepAlive() {
        guard !keepAliveHeld else { return }
        keepAliveHeld = true
        BackgroundLocationManager.shared.requestStart()
    }

    private func releaseKeepAlive() {
        guard keepAliveHeld else { return }
        keepAliveHeld = false
        BackgroundLocationManager.shared.requestStop()
    }

    @State private var moveTimer: Timer?
    @State private var showPaywall = false
    @State private var joyFraction: Double = 0
    // Humanizes the raw stick input: subtle pace variation + a gently-wandering heading so the
    // walk isn't a ruler-straight line at a dead-constant speed. Steered ⇒ never a full stop.
    @State private var motion = HumanizedMotion(context: .steered)
    // Hands-free destination: when set, the avatar walks itself here (autonomous ⇒ full realism,
    // incl. micro-pauses) until it arrives. Grabbing the joystick cancels it.
    @State private var autoWalkTarget: CLLocationCoordinate2D?

    // MARK: Hands-free patterns (Roam / Orbit)
    //
    // Both run through `step()` like every other mode: they choose this tick's INTENDED heading and
    // hand it to the same HumanizedMotion instance, which adds the pace wobble, heading drift and
    // micro-pauses. Nothing here moves the coordinate itself and nothing here sends a fix — that
    // stays in one place, so this view remains the single location writer during a run.
    @State private var pattern: AutoPattern?
    /// The course Roam is currently walking. Steered gradually (see `roamBearing`) rather than
    /// re-randomised per tick, because a heading that jumps every second isn't a walk, it's static.
    @State private var roamCourse: Double = 0
    /// The course Roam is turning TOWARD, and how many ticks until it picks another one. A person
    /// wandering a park holds a direction for tens of seconds, not for one.
    @State private var roamCourseTarget: Double = 0
    @State private var roamTicksToTurn: Int = 0
    /// Radians of arc Orbit has covered since its last dwell — i.e. how far around this lap we are.
    /// Measured as arc rather than by watching the avatar re-cross a start bearing, which the
    /// humanized heading drift would trip early or miss entirely.
    @State private var orbitLapArc: Double = 0
    /// Ticks left of an Orbit dwell (standing at the pin). Counted in ticks, not a deadline, so a
    /// backgrounded/stalled tick loop can't silently shorten the pause.
    @State private var dwellTicksLeft: Int = 0

    /// Pattern settings are preferences, not session state: someone farming a lured stop wants the
    /// same 40 m orbit tomorrow. Stored in metres/seconds so switching km/mi can't move them.
    @AppStorage("roamRadiusMeters") private var roamRadius: Double = 250
    @AppStorage("orbitRadiusMeters") private var orbitRadius: Double = 40
    @AppStorage("orbitDwellSeconds") private var orbitDwellSeconds: Double = 0
    @AppStorage("orbitClockwise") private var orbitClockwise = true
    /// Collapsed by default so the joystick screen looks exactly as it did for anyone not farming.
    @State private var showHandsFree = false
    /// The user's own saved spots, so Orbit can circle "the lured stop I bookmarked" instead of
    /// only whatever pin happens to be under the avatar right now.
    @StateObject private var savedPlaces = SavedPlacesStore()

    /// How close to the boundary Roam starts easing back inward, as a fraction of the radius.
    /// Starting at 60% leaves the whole outer third of the circle as turning room, which is what
    /// keeps the turn a curve instead of a screensaver bounce off a wall.
    private static let roamTurnInFrom: Double = 0.6
    /// Base turn rate, plus the extra allowed right at the edge. A stroll changes direction slowly;
    /// the edge boost exists so containment still holds at driving speeds, where the same 40 m of
    /// turning room passes in three seconds instead of twenty.
    private static let roamTurnRate: Double = 25 * .pi / 180        // rad/s
    private static let roamTurnRateAtEdge: Double = 65 * .pi / 180  // rad/s, added on top

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
    /// The heading the last tick actually walked, whichever mode chose it. Only "Lock heading" reads
    /// it: locking out of a Roam/Orbit run has to continue the course that's visibly being walked,
    /// and the knob is centred in those modes so the stick history would pin something stale.
    @State private var lastWalkedHeading: Double?

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
                savedPlaces.reload()   // the user's own spots, offered as Orbit centres
                // Roll the daily bucket here too, not just while moving: opening the tab the morning
                // after a farm run must read "Today 0", not yesterday's total.
                rollDailyBucketIfNeeded()
                // Returning to an in-progress walk: restart our tick so we re-take ownership
                // (step() re-asserts suppressResends) and resume keeping the fix warm — otherwise the
                // stopped timer would leave the joystick dead until the user hit Stop and restarted.
                if isWalking { startTimer() }
            }
            // Keep the Orbit centre list in step with the Places tab / sync, so a spot saved a
            // minute ago is offerable without leaving and re-entering the tab.
            .onReceive(NotificationCenter.default.publisher(for: .placesDidChange)) { _ in
                savedPlaces.reload()
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
            // The pattern's playing field, drawn because "stay inside 250 m of here" is meaningless
            // until you can see where that is — and because seeing the avatar curve away from the
            // ring is the only way to trust that it won't wander off across town unattended.
            if let field = patternField {
                MapCircle(center: field.center, radius: field.radius)
                    .foregroundStyle(Wander.brand.opacity(0.12))
                    .stroke(Wander.brand.opacity(0.65), lineWidth: 2)
                Annotation(L("joystick.pattern.center", fallback: "Centre"), coordinate: field.center) {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.footnote)
                        .foregroundStyle(Wander.brand)
                }
            }
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
                    // Roam / Orbit take the same seat as auto-walk — all three are "the app is
                    // walking, not you" — so a running pattern replaces the picker rather than
                    // sitting beside it offering a second hands-free mode to start.
                    if pattern != nil {
                        patternActiveRow
                    } else {
                        handsFreeSection
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
            // The card hugs its content, so the collapsed screen is unchanged; it only grows (and
            // becomes scrollable) once the hands-free section is expanded and the radius/dwell rows
            // are on screen. Without this the expanded group would push the Stop button off-screen.
            .hugScrollCard(maxHeight: UIScreen.main.bounds.height * 0.55)
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

    // MARK: - Hands-free pattern UI (Roam / Orbit)

    /// The circle a running pattern is bound to, for the map overlay. nil when nothing is running.
    private var patternField: (center: CLLocationCoordinate2D, radius: Double)? {
        switch pattern {
        case .roam(let center, let radius): return (center, radius)
        case .orbit(let center, let radius, _, _): return (center, radius)
        case nil: return nil
        }
    }

    /// What's running, in words. The state has to be spelled out: the knob sits centred while a
    /// pattern walks (nobody's touching it), which on its own reads as "stopped".
    private var patternStatusText: String {
        switch pattern {
        case .roam(_, let radius):
            return String(format: L("joystick.roam.active", fallback: "Roaming inside %@ — hands-free"),
                          radiusText(radius))
        case .orbit(_, let radius, let clockwise, let dwell):
            let direction = clockwise
                ? L("joystick.orbit.cw", fallback: "clockwise")
                : L("joystick.orbit.ccw", fallback: "anticlockwise")
            let base = String(format: L("joystick.orbit.active", fallback: "Orbiting at %@, %@"),
                              radiusText(radius), direction)
            guard dwell > 0 else { return base }
            return base + String(format: L("joystick.orbit.active_dwell", fallback: " • %d s pause each lap"),
                                 Int(dwell))
        case nil:
            return ""
        }
    }

    /// Status plus the gentle exit while a pattern runs. "Park here" is deliberately NOT the red
    /// Stop: someone who parked on a lured stop to farm wants to keep the spot when they're done,
    /// and Stop clears the spoof entirely.
    private var patternActiveRow: some View {
        HStack(spacing: 8) {
            Label(patternStatusText, systemImage: dwellTicksLeft > 0 ? "pause.circle.fill" : "circle.dashed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Wander.brand)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("joystick.pattern.park", fallback: "Park here")) { parkInPlace() }
                .buttonStyle(.borderedProminent)
                .tint(Wander.brand)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Roam + Orbit setup, collapsed by default so the joystick screen is unchanged for anyone who
    /// isn't farming. Mirrors the Route tab's "More options" disclosure.
    private var handsFreeSection: some View {
        DisclosureGroup(isExpanded: $showHandsFree) {
            VStack(alignment: .leading, spacing: 12) {
                roamControls
                Divider()
                orbitControls
            }
            .padding(.top, 6)
        } label: {
            Label(L("joystick.handsfree", fallback: "Hands-free — roam an area, orbit a spot"),
                  systemImage: "figure.walk.motion")
                .font(.subheadline.weight(.medium))
        }
        .tint(Wander.brand)
    }

    private var roamControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("joystick.roam.title", fallback: "Roam this area"))
                .font(.caption.weight(.semibold))
            radiusChips(Self.roamRadiusChoices, selected: roamRadius) { roamRadius = $0 }
            Text(L("joystick.roam.hint",
                   fallback: "Walks a wandering path around your current spot and never leaves the circle. Uses the speed above and stops on your distance goal."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                startRoam()
            } label: {
                Label(L("joystick.roam.start", fallback: "Start roaming"), systemImage: "arrow.triangle.turn.up.right.circle")
                    .frame(maxWidth: .infinity).frame(height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Wander.brand)
        }
    }

    private var orbitControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("joystick.orbit.title", fallback: "Orbit a spot"))
                .font(.caption.weight(.semibold))
            radiusChips(Self.orbitRadiusChoices, selected: orbitRadius) { orbitRadius = $0 }
            HStack(spacing: 6) {
                Text(L("joystick.orbit.dwell", fallback: "Pause each lap"))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.orbitDwellChoices, id: \.self) { seconds in
                            Button(seconds == 0
                                   ? L("joystick.orbit.dwell.none", fallback: "None")
                                   : "\(Int(seconds))s") {
                                orbitDwellSeconds = seconds
                                Haptics.selection()
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(orbitDwellSeconds - seconds) < 0.5 ? Wander.brand : nil)
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Toggle(isOn: $orbitClockwise) {
                Text(L("joystick.orbit.clockwise", fallback: "Clockwise"))
                    .font(.caption)
            }
            .tint(Wander.brand)
            Text(L("joystick.orbit.hint",
                   fallback: "Circles the pin so distance keeps accruing while you stay in range of it — pick one of your saved spots, or circle where you're standing."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu {
                Button(L("joystick.orbit.center_here", fallback: "Around this spot")) { startOrbit(center: nil) }
                if !savedPlaces.saved.isEmpty {
                    Section(L("places.saved", fallback: "Saved")) {
                        // Only the user's OWN bookmarks — this list never suggests somewhere to go.
                        ForEach(savedPlaces.saved) { place in
                            Button(place.name) { startOrbit(center: place.coordinate) }
                        }
                    }
                }
            } label: {
                Label(L("joystick.orbit.start", fallback: "Start orbit"), systemImage: "circle.dashed")
                    .frame(maxWidth: .infinity).frame(height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Wander.brand)
        }
    }

    /// Radius chips shared by Roam and Orbit. The VALUES are metres either way — only the labels
    /// convert — so switching km/mi can't silently resize somebody's saved farming circle.
    private func radiusChips(_ choices: [Double], selected: Double,
                             onPick: @escaping (Double) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(choices, id: \.self) { meters in
                    Button(radiusText(meters)) {
                        onPick(meters)
                        Haptics.selection()
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(selected - meters) < 1 ? Wander.brand : nil)
                    .font(.caption)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private static let roamRadiusChoices: [Double] = [100, 250, 500, 1000]
    private static let orbitRadiusChoices: [Double] = [20, 40, 80, 150]
    private static let orbitDwellChoices: [Double] = [0, 10, 30, 60]

    /// A radius in the unit the user reads in. Feet below a quarter-mile: "0.02 mi" is a useless
    /// way to describe a 40 m orbit.
    private func radiusText(_ meters: Double) -> String {
        if useMph {
            let miles = meters / 1609.34
            return miles < 0.25 ? "\(Int((meters * 3.28084).rounded())) ft" : String(format: "%.2f mi", miles)
        }
        return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
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
                            if autoWalkTarget != nil || pattern != nil {
                                autoWalkTarget = nil
                                pattern = nil
                                dwellTicksLeft = 0
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
        holdKeepAlive()
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
        releaseKeepAlive()
        isWalking = false
        autoWalkTarget = nil
        pattern = nil
        dwellTicksLeft = 0
        lockedHeading = nil
        lastStickBearing = nil
        lastWalkedHeading = nil
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

        // Pick this tick's intended heading + speed from whichever mode is active. Every branch
        // ends at the SAME humanized step below — a mode chooses a direction, it never moves the
        // avatar itself, so there is exactly one movement engine and one writer.
        let baseBearing: Double
        let targetSpeed: Double
        var remaining = Double.greatestFiniteMagnitude
        // Hoisted above the mode switch because Orbit has to aim with the SAME ceiling the step is
        // walked under (see below for what the clamp is and why it can't be turned off).
        let clampPreset: GamePreset? = gameSpeedWarn ? gamePreset : nil
        if let pattern {
            // Roam / Orbit: the shape is the user's, the heading is ours. Speed stays the slider's,
            // so the Walk/Run/Drive presets and the game speed guardrail below still apply.
            switch pattern {
            case .roam(let center, let radius):
                baseBearing = roamBearing(from: coord, center: center, radius: radius)
            case .orbit(let center, let radius, let clockwise, let dwellSeconds):
                if dwellTicksLeft > 0 {
                    // Standing at the pin for this lap's dwell. Same treatment as a centred stick:
                    // the map resend is suppressed for the whole run, so keep the CURRENT fix warm
                    // ourselves on the slow cadence or iOS drops the spoof while we pause.
                    dwellTicksLeft -= 1
                    idleTicks += 1
                    if idleTicks >= idleResendEveryTicks {
                        idleTicks = 0
                        send(coord)
                    }
                    return
                }
                baseBearing = orbitBearing(from: coord, center: center, radius: radius,
                                           clockwise: clockwise, dwellSeconds: dwellSeconds,
                                           governedSpeed: SpeedGovernor.clampSpeedMps(speedMps, preset: clampPreset))
            }
            targetSpeed = speedMps
            idleTicks = 0
        } else if let target = autoWalkTarget {
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
        lastWalkedHeading = heading
        // HARD speed clamp (ALWAYS ON, not user-disableable): cap the per-tick advance so the
        // effective ground speed can never exceed a ban-triggering ceiling — even if the slider (or
        // the humanized pace variance) pushed it higher. Applies to both joystick and auto-walk. If
        // the user opted into a game context (gameSpeedWarn) we cap at THAT game's community-cited
        // safe speed; otherwise SpeedGovernor uses its absolute ~35 km/h fallback. Either way the cap
        // is applied every tick. The soft `gameSpeedWarn` above still fires as a nudge; this is the
        // safety net that can't be turned off. (`clampPreset` is resolved above the mode switch.)
        let cappedSpd = SpeedGovernor.clampSpeedMps(spd, preset: clampPreset)
        var distance = autoWalkTarget != nil ? min(cappedSpd * tickInterval, remaining) : cappedSpd * tickInterval
        // Distance goal: shorten the LAST step so we land on the number instead of sailing past it.
        // "Stop at 5 km" has to actually read 5.00 km, because the first thing a farmer does is
        // compare our counter against the game's. This trims a step, never a speed — the speed
        // guardrail above stays the only thing allowed to touch pace.
        let goalRemaining = goalMeters > 0
            ? max(goalMeters - goalProgressMeters, 0)
            : Double.greatestFiniteMagnitude
        let goalStep = distance >= goalRemaining
        if goalStep { distance = goalRemaining }

        let metersPerDegLat = 111_320.0
        let dLat = (distance * cos(heading)) / metersPerDegLat
        let lonScale = max(cos(coord.latitude * .pi / 180), 0.000001)
        let dLon = (distance * sin(heading)) / (metersPerDegLat * lonScale)

        let stepFrom = coord
        coord.latitude += dLat
        coord.longitude += dLon
        // Roam containment backstop. The steering in `roamBearing` is what MAKES the turn look
        // human, but it's a soft guarantee — a big enough speed against a small enough circle can
        // out-run any turn rate. This is the hard one: the avatar slides along the boundary for the
        // second or two the turn needs instead of stepping outside the area the user drew.
        if case .roam(let center, let radius)? = pattern {
            coord = clampedInside(coord, center: center, radius: radius)
        }
        // Count what we ACTUALLY moved, not what we intended: a clamped step is shorter than the
        // humanized engine asked for, and the distance counter is the number a farmer checks
        // against the game's.
        let applied = distanceMeters(stepFrom, coord)
        // …and only call the goal DONE if the step we actually walked closed the gap. Under Roam the
        // containment clamp can trim that last step, and announcing "goal reached" while the counter
        // still reads short of the target breaks the one invariant this feature sells ("Stop at 5 km"
        // must read 5.00 km). The half-metre slack absorbs planar-vs-geodesic rounding between the
        // step we computed and the distance we measured — without it an unclamped final step could
        // land a few centimetres short and leave the goal chasing a remainder that never closes.
        let goalHit = goalStep && applied >= goalRemaining - 0.5
        coordinate = coord            // clean humanized path: display + next-tick anchor
        recenter(on: coord)
        // Scatter only the REPORTED fix by a few metres of receiver error, so consecutive points
        // don't trace a perfect line. Keeps `coord` clean for the map + Health. Gated on the step
        // being LARGER than the noise radius: at a tiny nudge the ±2.5 m random scatter would
        // dominate a sub-metre step and read as jumpy, near-teleport motion (a second Error-12
        // trigger), so send the clean point for small steps. A goal-completing step is also sent
        // clean: we park on it, and the hold we hand back re-asserts this exact coordinate — a
        // scattered final fix would leave the parked point 2 m off the one we counted.
        let reported = (MotionRealism.isEnabled && applied > 2.5 && !goalHit) ? HumanizedMotion.gpsNoise(coord) : coord
        send(reported)
        // Adventure Sync: mirror this simulated step into Health (no-op unless opted
        // in). Derived from the ACTUAL per-tick movement, at a human cadence.
        AdventureSyncManager.shared.recordSimulatedMovement(to: coord)
        // Count what we actually moved, then land the goal if this was the step that finished it.
        accumulateDistance(applied)
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
        holdKeepAlive()
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
        releaseKeepAlive()
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

    // MARK: - Roam / Orbit (unattended patterns)

    /// Start wandering inside `roamRadius` metres of where the avatar stands right now. That pin is
    /// the centre precisely BECAUSE the user already chose it (searched it, dropped it, teleported
    /// to it) — asking them to pick a second one would be asking the same question twice.
    private func startRoam() {
        guard let coordinate else { return }
        guard beginHandsFreeRun() else { return }
        // Seed the course from wherever the stick last pointed, so "push, then start roaming" heads
        // off the way the user was already facing instead of snapping to due north.
        roamCourse = lastStickBearing ?? Double.random(in: 0..<(2 * .pi))
        roamCourseTarget = roamCourse
        roamTicksToTurn = 0
        pattern = .roam(center: coordinate, radius: max(roamRadius, 50))
        launchHandsFreeRun(from: coordinate)
    }

    /// Start circling a pin. `center` nil ⇒ circle where the avatar is standing; otherwise circle
    /// one of the user's OWN saved spots, moving the start pin there first (the same thing setting a
    /// start point does — no new location is invented, it's a bookmark they made).
    private func startOrbit(center: CLLocationCoordinate2D?) {
        let target = center ?? coordinate
        guard let target else { return }
        guard beginHandsFreeRun() else { return }
        if center != nil {
            // Circling a saved spot RELOCATES the avatar — possibly across continents — before the
            // first step, so it is a teleport and has to be booked as one. Without this the soft-ban
            // countdown reads "clear" the instant after a long jump (jump-then-interact is exactly
            // what gets accounts flagged, and orbiting a bookmarked lured stop is the whole point of
            // this button), the NEXT teleport would measure its cooldown from the stale pre-orbit
            // point, and a free user would get the jump unmetered. Same bookkeeping every other
            // instantaneous relocation does — see MapSelectionView.performSimulateInner / glideTeleport.
            coordinate = target
            SimulationSession.shared.noteTeleport(to: target)
            if !License.shared.isLicensed { TrialManager.shared.chargeTeleport() }
            // Re-show the advisory: beginHandsFreeRun() only saw the PRE-jump cooldown, and the
            // cooldown that actually matters is the one this jump just armed.
            noteCooldownIfActive()
        }
        orbitLapArc = 0
        dwellTicksLeft = 0
        pattern = .orbit(center: target,
                         radius: max(orbitRadius, 10),
                         clockwise: orbitClockwise,
                         dwellSeconds: max(orbitDwellSeconds, 0))
        // Starting from the centre is normal (you're standing on the lured stop): the first few
        // ticks walk out to the ring and it starts circling from there — no teleport onto the rim.
        launchHandsFreeRun(from: target)
    }

    /// The gates every hands-free run has to pass, in one place: pairing file, licence/trial, and
    /// the non-blocking cooldown advisory. Returns false when the run must not start.
    private func beginHandsFreeRun() -> Bool {
        guard pairingFilePath() != nil else {
            alert("Pairing file required", "Import a pairing file in Settings before simulating location.")
            coordinate = nil
            return false
        }
        if !License.shared.isLicensed && !TrialManager.shared.canUse(.joystick) {
            showPaywall = true
            return false
        }
        // Advisory only (never blocks): remind about a running soft-ban cooldown before we move.
        noteCooldownIfActive()
        return true
    }

    /// Take over the location stream and start ticking. Mirrors `startAutoWalk` exactly — same
    /// keep-alive hold, same single-writer suppression, same autonomous gait — because these are
    /// the same kind of run: the app is walking and the phone is in a pocket.
    private func launchHandsFreeRun(from origin: CLLocationCoordinate2D) {
        autoWalkTarget = nil       // one hands-free mode at a time
        lockedHeading = nil
        knobOffset = .zero         // defensive: ensure step() takes the pattern path, not the stick
        holdKeepAlive()
        isWalking = true
        // Own the stream: suppress the Map tab's stale teleport resend for the duration (see start()).
        LocationSimulationCommandQueue.suppressResends = true
        // Moving writer now — stand the stationary snap-back watcher down (see start()).
        SimulationSession.shared.movementModeDidBecomeActiveWriter()
        motion = HumanizedMotion(context: .autonomous)   // hands-free ⇒ full realism incl. micro-pauses
        SimulationSession.shared.started()
        beginDistanceSession()
        AdventureSyncManager.shared.beginWalk()
        send(origin)
        recenter(on: origin)
        startTimer()
        Haptics.medium()
    }

    /// Roam's heading for this tick: hold a course for a while, then pick another — and lean back
    /// toward the middle as the edge approaches, so the turn is a curve a person could walk rather
    /// than the hard reflection of a screensaver.
    private func roamBearing(from coord: CLLocationCoordinate2D,
                             center: CLLocationCoordinate2D,
                             radius: Double) -> Double {
        let inward = bearingRad(from: coord, to: center)
        let distanceOut = distanceMeters(coord, center) / max(radius, 1)

        // Hold a course for 20–45 s at a time. A heading re-rolled every tick would average out to
        // standing still and jitter the trace; holding one is what makes it read as "going somewhere".
        if roamTicksToTurn <= 0 {
            roamTicksToTurn = max(1, Int(Double.random(in: 20...45) / tickInterval))
            roamCourseTarget = roamCourse + Double.random(in: -1.2...1.2)   // ±~70°
        } else {
            roamTicksToTurn -= 1
        }

        // 0 in the middle of the circle, ramping to 1 at the boundary: how much of the course is
        // "head back inside" versus wherever we were going.
        let edge = min(max((distanceOut - Self.roamTurnInFrom) / (1 - Self.roamTurnInFrom), 0), 1)
        if edge > 0.9 {
            // Committed to turning back. Re-aim the HELD course inward too (not just this tick's
            // blend), or the moment we're back inside the old outward course would take us straight
            // at the boundary again and the walk would pinball along the rim.
            roamCourseTarget = inward + Double.random(in: -0.5...0.5)
            roamTicksToTurn = max(1, Int(Double.random(in: 20...45) / tickInterval))
        }

        let desired = blendedHeading(roamCourseTarget, toward: inward, fraction: edge)
        let turnRate = Self.roamTurnRate + Self.roamTurnRateAtEdge * edge
        roamCourse = turned(roamCourse, toward: desired, maxDelta: turnRate * tickInterval)
        return roamCourse
    }

    /// Orbit's heading for this tick: aim at the next point ALONG the ring rather than at a fixed
    /// tangent. Aiming at the true ring is self-correcting — the humanized heading drift pushes the
    /// avatar a metre or two off the circle every few seconds, and a tangent-only heading would
    /// integrate that error into a slow spiral outward.
    private func orbitBearing(from coord: CLLocationCoordinate2D,
                              center: CLLocationCoordinate2D,
                              radius: Double,
                              clockwise: Bool,
                              dwellSeconds: Double,
                              governedSpeed: Double) -> Double {
        let here = bearingRad(from: center, to: coord)
        // Arc this tick's step covers, from the speed the step will ACTUALLY be walked at — i.e.
        // after the hard speed governor, not the raw slider. With the Drive preset (50 km/h) against
        // the ~35 km/h ceiling the two disagree by ~43%, and aiming at a ring point further round
        // than the avatar can reach makes every tick cut a chord inside the circle (traced radius
        // visibly under the chosen one) while `orbitLapArc` runs ~43% fast, firing the per-lap dwell
        // before a lap has happened. The presets still change how fast the laps go round — up to the
        // ceiling — not the shape of the circle.
        let arc = (governedSpeed * tickInterval) / max(radius, 5)
        let next = here + (clockwise ? arc : -arc)

        // Lap accounting for the dwell. Counted as arc travelled rather than by watching the avatar
        // re-cross its start bearing, which the humanized drift would trip a few degrees early or
        // skip entirely on a fast lap.
        if dwellSeconds > 0 {
            orbitLapArc += arc
            if orbitLapArc >= 2 * .pi {
                orbitLapArc -= 2 * .pi
                dwellTicksLeft = max(1, Int(dwellSeconds / tickInterval))
            }
        }
        return bearingRad(from: coord, to: point(from: center, bearing: next, meters: radius))
    }

    /// Pull a coordinate back onto the boundary circle if it stepped outside. Projecting along the
    /// bearing from the centre makes the avatar SLIDE along the edge for the second the turn needs,
    /// which is far less conspicuous than a bounce and can't overshoot into a jump.
    private func clampedInside(_ c: CLLocationCoordinate2D,
                               center: CLLocationCoordinate2D,
                               radius: Double) -> CLLocationCoordinate2D {
        guard distanceMeters(c, center) > radius else { return c }
        return point(from: center, bearing: bearingRad(from: center, to: c), meters: radius)
    }

    /// The point `meters` away from `c` on `bearing`, in the same planar convention the rest of this
    /// view moves in (0 = north, +east) so a stepped point and an aimed point can't disagree.
    private func point(from c: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let metersPerDegLat = 111_320.0
        let lonScale = max(cos(c.latitude * .pi / 180), 0.000001)
        return CLLocationCoordinate2D(
            latitude: c.latitude + (meters * cos(bearing)) / metersPerDegLat,
            longitude: c.longitude + (meters * sin(bearing)) / (metersPerDegLat * lonScale)
        )
    }

    /// Interpolate between two headings along the SHORT arc. Naively averaging radians turns a
    /// 350°→10° blend into a 180° detour, which on the map is the avatar spinning on the spot.
    private func blendedHeading(_ from: Double, toward to: Double, fraction: Double) -> Double {
        from + shortestAngle(from: from, to: to) * min(max(fraction, 0), 1)
    }

    /// Turn `from` toward `to` by at most `maxDelta` radians — the rate limiter that makes a change
    /// of direction a turn instead of an instant pivot.
    private func turned(_ from: Double, toward to: Double, maxDelta: Double) -> Double {
        from + min(max(shortestAngle(from: from, to: to), -maxDelta), maxDelta)
    }

    /// Signed shortest angular difference, wrapped into ±π.
    private func shortestAngle(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
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

    /// The goal was reached on this tick: stop moving but STAY here.
    private func completeDistanceGoal() {
        parkInPlace()
        goalCompleted = true
        Haptics.medium()
    }

    /// Stop moving and stay exactly where we are. This is the auto-walk arrival landing (settle,
    /// hand the warm-hold back to the Map tab's resend), not the red Stop button's teardown — the
    /// whole point of farming to a spot is that you keep the spot.
    ///
    /// Shared by the distance goal and the hands-free patterns' "Park here", because both mean the
    /// same thing to the user and a second near-copy of this teardown is how one of them ends up
    /// forgetting to release the keep-alive.
    private func parkInPlace() {
        AdventureSyncManager.shared.endWalk()
        autoWalkTarget = nil
        pattern = nil
        dwellTicksLeft = 0
        releaseHeadingLock(resetGait: false)
        releaseKeepAlive()
        isWalking = false
        knobOffset = .zero
        idleTicks = 0
        stopTimer()
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
        } else if pattern != nil, let walked = lastWalkedHeading {
            // Same hand-off out of a Roam/Orbit run: the course being walked IS the direction the
            // user means. Locking here means "stop going round in circles and carry straight on".
            bearing = walked
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
        // One hands-free mode at a time. When we got here from a live auto-walk (or a Roam/Orbit
        // run) this is a hand-off, not a cancellation: the lock carries on along the exact course
        // that was being walked, so the avatar keeps going in a straight line — it just no longer
        // stops at the destination or turns back at the boundary.
        autoWalkTarget = nil
        pattern = nil
        dwellTicksLeft = 0
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
