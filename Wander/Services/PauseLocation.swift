//
//  PauseLocation.swift
//  Wander
//
//  PAUSE — "freeze me where I am". You are at home, Find My shows you at home, you tap Pause, you
//  leave, and you keep showing at home. The exact inverse of the panic button (wander://panic),
//  which reverts you to your real GPS.
//
//  The word matters, so it is written down once here. The VERB is "Pause" — the owner's word, and
//  what the button says. The STATE is "Frozen", never "Paused": "paused" reads as "nothing is
//  happening", which is the precise misunderstanding that gets somebody walking around believing
//  they are broadcasting live. "Hold" is deliberately not reused — `holdKeepAlive` and
//  `.holdLocationRequested` already mean something different internally, and "hold perfectly still"
//  was a retired user-facing toggle.
//
//  ── PAUSE IS A START ──────────────────────────────────────────────────────────────────────────
//  The fake location is connection-scoped: it dies with the app or the tunnel (see
//  `LocationWriteGuards`). So "pause" is not a suspension of anything — it is "start spoofing, at
//  this exact point", and it goes through the same start gate every other start path uses.
//
//  ── THE SINGLE-WRITER RULE ────────────────────────────────────────────────────────────────────
//  OTA 92: two writers fighting over the stream is what produced the backward jumps that made
//  Pokémon GO throw "Failed to detect location (12)". Pause must TAKE OWNERSHIP of the stream, not
//  race whatever mode was running. The two-step protocol is already encoded in the tree and this
//  file uses it verbatim rather than inventing one:
//
//    1. post `.stopSimulationRequested` SYNCHRONOUSLY — the views honour it on the posting thread
//       via SwiftUI `onReceive`, so they are stood down by the time the post returns;
//    2. arm on a Task created AFTER that broadcast — `ItineraryRunner` defers its teardown by one
//       main-actor hop, and the main actor runs unstructured tasks in creation order, so a task
//       created here is guaranteed to run after that teardown (and its echo) has finished.
//
//  ── PAUSE DOES NOT ADD A FIFTH HOLD LOOP ──────────────────────────────────────────────────────
//  There are already four things in this app that hold a parked point alive:
//  `MapSelectionView.startResendLoop`, `WalkModeView`'s idle re-assert, `ItineraryRunner.stay`, and
//  `RouteModeView`'s paused loop. The first of those IS the pause engine already — it holds a
//  coordinate, breathes it through `BreathingJitter` so a parked spot wanders ~1–3 m and drifts
//  back like a real stationary receiver, and is the sole writer while it runs. Pause becomes the
//  NAMED OWNER of that loop (by posting `.holdLocationRequested`, exactly as walk/route/Shortcuts
//  already do when they park) rather than growing a fifth one.
//
//  That is also why Pause must not freeze rock-still. `BreathingJitter`'s own header names the
//  detection risk: "a dead point looks parked-but-too-perfect". Pause holds the ANCHOR and lets the
//  REPORTED point breathe. Freezing the sharing use case perfectly still is the one way to make it
//  LESS believable, not more.
//

import Foundation
import CoreLocation
import Combine

// MARK: - Where the injected point actually is, right now

/// The live "where is Wander injecting, this second" record.
///
/// This did not exist, and Pause cannot work without it. Every writer knew only its own position —
/// `WanderLinkAutomation.currentCoordinate`, `RouteModeView.currentPosition`,
/// `WalkModeView.coordinate`, `ItineraryRunner`'s current step — and
/// `SimulationSession.lastTeleportCoordinate` is the last PARKED point, which goes stale the moment
/// anything starts moving (its own comment says so). `TunnelInjectStatus` records timestamps only,
/// no coordinate. So there was no cross-mode answer to "freeze me where I am".
///
/// Written at each writer's EXISTING send choke-point — one line each, at five call sites that are
/// already deliberate single choke-points. It is deliberately NOT implemented as "each writer
/// answers a `.pauseRequested` notification with its own point": that races when two writers
/// briefly overlap, and the entire feature is about there being exactly one.
///
/// Lock-guarded and `nonisolated` because every one of those choke-points runs on the serial
/// location queue, not the main actor.
enum InjectedLocationRecord {
    private static let lock = NSLock()
    private static var _latitude: Double?
    private static var _longitude: Double?

    static func note(_ coordinate: CLLocationCoordinate2D) {
        lock.lock()
        _latitude = coordinate.latitude
        _longitude = coordinate.longitude
        lock.unlock()
    }

    /// Called when a session ends, so a stale point from a finished run can never be frozen onto.
    static func clear() {
        lock.lock()
        _latitude = nil
        _longitude = nil
        lock.unlock()
    }

    static var coordinate: CLLocationCoordinate2D? {
        lock.lock()
        defer { lock.unlock() }
        guard let lat = _latitude, let lng = _longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

extension SimulationSession {
    /// Record the point a writer just injected. Safe from the location queue.
    nonisolated static func noteInjected(_ coordinate: CLLocationCoordinate2D) {
        InjectedLocationRecord.note(coordinate)
    }

    /// Where Wander is injecting right now, across every mode. `nil` when nothing is writing.
    nonisolated static var currentInjectedCoordinate: CLLocationCoordinate2D? {
        InjectedLocationRecord.coordinate
    }
}

// MARK: - The controller

@MainActor
final class PauseController: ObservableObject {
    static let shared = PauseController()

    /// What Pause is doing. `frozen` is the only one the user is told about by name.
    enum Stage: Equatable {
        case idle
        /// Looking for a real fix good enough to freeze on. NOTHING has been written to the device
        /// in this stage — that is the point of it.
        case finding
        /// A point has been chosen; bringing the transport up and writing it.
        case arming
        case frozen
    }

    /// What the flow sheet is showing. Absent means no sheet.
    enum Flow: Identifiable {
        case finding
        /// The deadline passed with nothing inside budget. Carries the best we saw, so the offer
        /// can name its real error rather than warn generically.
        case bestEffort(FreshFixFinder.Fix)
        case refused(FreshFixFinder.Refusal)
        case failed(title: String, message: String)

        var id: String {
            switch self {
            case .finding: return "finding"
            case .bestEffort: return "bestEffort"
            case .refused(let r): return "refused-\(r)"
            case .failed(let title, _): return "failed-\(title)"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published var flow: Flow?
    /// Set when a free user has run out of teleport allowance. The UI raises the paywall and
    /// clears it — Pause writes nothing in the meantime.
    @Published var needsPaywall = false

    /// Where we are frozen, and since when. Both nil unless `stage == .frozen`.
    @Published private(set) var frozenAt: CLLocationCoordinate2D?
    @Published private(set) var frozenSince: Date?

    /// The live acquisition, exposed so the sheet can show the accuracy falling in real time.
    let finder = FreshFixFinder()

    var isFrozen: Bool { stage == .frozen }

    private var cancellables = Set<AnyCancellable>()
    private var stopObserver: NSObjectProtocol?

    private init() {
        // A stop from ANYWHERE ends the freeze. Registered `queue: nil` — i.e. synchronously on the
        // poster's thread — for the same reason `WanderLinkAutomation` does: our own stand-down
        // broadcast has to land BEFORE the arm task we create after it, not a turn later. The arm
        // sets `.frozen` again on the far side, so our own broadcast clearing the stage here is
        // correct sequencing rather than a race.
        stopObserver = NotificationCenter.default.addObserver(
            forName: .stopSimulationRequested, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.clearFrozenState() }
            } else {
                Task { @MainActor in self?.clearFrozenState() }
            }
        }

        // The Map tab's own Stop (`markStopped`) does NOT broadcast, so the observer above cannot
        // see it. The session going inactive covers every stop path there is.
        SimulationSession.shared.$isActive
            .sink { [weak self] active in
                guard let self, !active else { return }
                InjectedLocationRecord.clear()
                self.clearFrozenState()
            }
            .store(in: &cancellables)

        // Somebody teleported somewhere else while we were frozen (the map's Simulate, a saved
        // place, a Shortcut, the reboot-resume). We are no longer "frozen where you were", so the
        // chip must stop claiming it. Watching the tick covers every teleport path in the app with
        // no call sites to keep in sync; our own freeze sets `frozenAt` BEFORE calling
        // `noteTeleport`, so the distance is 0 and this correctly leaves us alone.
        SimulationSession.shared.$teleportTick
            .sink { [weak self] _ in
                guard let self, self.isFrozen, let held = self.frozenAt,
                      let latest = SimulationSession.shared.lastTeleportCoordinate else { return }
                let moved = CLLocation(latitude: held.latitude, longitude: held.longitude)
                    .distance(from: CLLocation(latitude: latest.latitude, longitude: latest.longitude))
                if moved > 25 { self.clearFrozenState() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry points

    /// The verb, toggle-aware, so one shortcut file can serve both directions.
    /// `nil` = toggle, `true` = freeze, `false` = unfreeze.
    func request(state: Bool?) {
        switch state {
        case .some(true): pause()
        case .some(false): unfreeze()
        case .none: isFrozen ? unfreeze() : pause()
        }
    }

    /// Freeze me where I am.
    func pause() {
        // SELF-HEAL A WEDGED ACQUISITION BEFORE GUARDING ON IT.
        //
        // Pause's worst failure mode is not an error — it is a tap where NOTHING VISIBLY HAPPENS,
        // because the user then walks away believing they are frozen when they are broadcasting
        // live. `.finding` with no finder actually running is exactly that shape: it would swallow
        // every subsequent tap in silence. It can arise whenever the flow sheet is dismissed or
        // pre-empted by another presentation without our dismissal handler running (the setup
        // checklist owning the presentation slot is a real instance of this — seen in the
        // simulator). `isRunning` is the finder's own truth, so this can only ever recover a stage
        // that is genuinely dead.
        if stage == .finding, !finder.isRunning {
            stage = .idle
            flow = nil
        }
        guard stage == .idle || stage == .frozen else { return }   // a run is already in flight
        guard !isFrozen else { return }

        // A LIVE SPOOF IS THE EASY CASE, and it skips the whole freshness problem.
        //
        // "Current" here is a point Wander owns exactly, so accuracy and age are meaningless — and
        // worse than meaningless: the injected fix is reported back through Core Location as
        // `horizontalAccuracy = 5.0` with age ≈ 0, so the error budget would PASS a spoofed fix and
        // tell us precisely nothing. Read the injected point directly instead.
        if SimulationSession.shared.isActive,
           let injected = SimulationSession.currentInjectedCoordinate
            ?? SimulationSession.shared.lastTeleportCoordinate {

            // A STATIC TELEPORT IS ALREADY FROZEN. `startResendLoop` is holding the point and
            // breathing it; `suppressResends == false` is that loop announcing it owns the stream.
            // Re-teleporting would bump `teleportTick` and re-arm the snap-back watcher for no gain,
            // so Pause here is a re-label and nothing else. Zero writes, zero risk.
            if !LocationSimulationCommandQueue.suppressResends {
                markFrozen(at: injected)
                LogManager.shared.addInfoLog("Pause: re-labelled a live teleport hold as Frozen (no write)")
                return
            }

            // A MOVEMENT MODE OWNS THE STREAM (joystick, route, itinerary, a link-driven run).
            // Stop it and park the point. Not "suspend" it: `WalkModeView` keeps a live timer that
            // re-asserts `suppressResends = true` every tick and re-arms itself in `onAppear`, so a
            // joystick left suspended is a second writer waiting to wake up the moment the user taps
            // the tab — the exact two-writer backward jump.
            beginFreeze(at: injected, chargeTrial: false)
            return
        }

        // NOT SPOOFING — the headline case, and the only one that can lie. "Current" means the REAL
        // fix, and `CLLocationManager.location` is a cached value that can be minutes old and
        // hundreds of metres away. Nothing is written until a fix passes; see `FreshFixFinder`.
        stage = .finding
        flow = .finding
        Task { @MainActor in
            let result = await finder.find()
            guard stage == .finding else { return }   // the user backed out
            switch result {
            case .success(let fix):
                LogManager.shared.addInfoLog(String(format: "Pause: froze on a fresh fix, %@ committed error, %.0fs old", fix.errorText, fix.ageSeconds))
                flow = nil
                beginFreeze(at: fix.coordinate, chargeTrial: true)
            case .failure(.noGoodFix):
                // DO NOT FREEZE SILENTLY, AND DO NOT FAIL SILENTLY. The asymmetry is the whole
                // argument: freeze on a bad fix and the user has already walked away and will never
                // look at the app again, so the error is unrecoverable; stop and ask and they lose
                // ten seconds. Those two costs are not remotely equal.
                stage = .idle
                if let best = finder.best {
                    flow = .bestEffort(best)
                } else {
                    flow = .refused(.noGoodFix)
                }
            case .failure(let refusal):
                stage = .idle
                flow = .refused(refusal)
            }
        }
    }

    /// The user chose to freeze on a fix we told them was not good enough. Their call, made with
    /// the real number in front of them.
    func freezeAnyway(on fix: FreshFixFinder.Fix) {
        flow = nil
        LogManager.shared.addInfoLog("Pause: user chose to freeze on a \(fix.errorText) fix")
        beginFreeze(at: fix.coordinate, chargeTrial: true)
    }

    /// Back out of an acquisition, or dismiss whatever the sheet is showing. Writes nothing.
    func cancelFlow() {
        if stage == .finding {
            stage = .idle
            finder.cancel()
        }
        flow = nil
    }

    /// The way out of Frozen.
    ///
    /// There is deliberately no "Resume" here. "Back to real GPS" is already spoken for five times
    /// over — the red panic button, `wander://panic`, the Home-screen quick action,
    /// `StopSpoofingIntent`, and the Location tab's Stop — and a sixth door called "Resume" would be
    /// the worst of them, because the word implies the opposite of what it does. Pause started from
    /// nothing has no prior state to resume TO, so its only exit is Stop. (A route paused mid-drive
    /// is the one case where "continue what I interrupted" is a real, different want, and
    /// `RouteModeView` already has that exact button — see `noteRoutePaused`.)
    func unfreeze() {
        guard isFrozen else { return }
        LogManager.shared.addInfoLog("Pause: unfroze (stop → real GPS)")
        SimulationSession.shared.stopAll()
    }

    // MARK: - Route pause hand-off

    /// The Route tab paused its drive at `coordinate`.
    ///
    /// This closes a real hole rather than just lighting a chip. `RouteModeView`'s playback loop
    /// answers `isPaused` by sleeping in 200 ms slices and SENDING NOTHING, while the map's resend
    /// stays suppressed for the whole drive — and `WalkModeView` states the consequence in the app's
    /// own words: something "must re-assert the current point every few seconds during a pause, or
    /// iOS drops the spoof". A route paused for more than a minute today has no writer at all.
    /// Handing the point to the parked writer fixes that and gives route pause the same frozen chip.
    func noteRoutePaused(at coordinate: CLLocationCoordinate2D) {
        NotificationCenter.default.post(
            name: .holdLocationRequested, object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        markFrozen(at: coordinate)
    }

    /// The Route tab resumed. It takes the writer role back (its own `send` re-asserts
    /// `suppressResends`), so all we do is drop the frozen label.
    func noteRouteResumed() {
        clearFrozenState()
    }

    // MARK: - Freezing

    /// Bring the transport up, take the stream, write the point, and hand the hold over.
    private func beginFreeze(at coordinate: CLLocationCoordinate2D, chargeTrial: Bool) {
        // The same gate every other start path uses. It costs NOTHING on a default install:
        // `TunnelStartGate.isNeeded` is false unless the user opted into Wander's own tunnel, so the
        // body runs synchronously with no task and no await. When it is needed it can take up to
        // 12 s, and a Stop landing inside that window wins (it snapshots `stopGeneration`).
        guard chargeTrial ? trialAllows() : true else { return }
        stage = .arming
        TunnelStartGate.then { [weak self] in
            guard let self else { return }
            // Step 1 — take ownership, synchronously. See the file header.
            NotificationCenter.default.post(name: .stopSimulationRequested, object: nil)
            // Step 2 — arm on a task created AFTER the broadcast.
            Task { @MainActor in await self.armFrozen(at: coordinate, chargeTrial: chargeTrial) }
        }
    }

    /// Free users draw down the same teleport allowance a tapped Simulate does — Pause is another
    /// door into the same engine, not a way around the meter.
    private func trialAllows() -> Bool {
        if License.shared.isLicensed { return true }
        if TrialManager.shared.canUse(.teleport) { return true }
        stage = .idle
        flow = nil
        needsPaywall = true
        return false
    }

    private func armFrozen(at coordinate: CLLocationCoordinate2D, chargeTrial: Bool) async {
        // Captured after the stand-down, exactly as every other writer does: a Stop landing while
        // our write is in flight must not be silently undone by us completing afterwards.
        let stopGen = SimulationSession.shared.stopGeneration

        guard let path = pairingFilePath() else {
            stage = .idle
            flow = .failed(
                title: L("pause.no_pairing.title", fallback: "Pairing file required"),
                message: L("pause.no_pairing.body", fallback: "Import a pairing file in Settings before Wander can hold your location.")
            )
            return
        }

        // WRITE THE POINT OURSELVES FIRST, then hand the hold over — the order
        // `WanderLocationIntent.teleport` already uses. Posting `.holdLocationRequested` alone would
        // leave a 4 s gap before the resend loop's first tick, and a stand-down that routed through
        // `ItineraryRunner` has just CLEARED the device location, so those 4 s would be spent on
        // real GPS. Writing first also gives us a real return code to report.
        let target = CoarseLocation.apply(coordinate)
        let code: Int32 = await withCheckedContinuation { cont in
            LocationSimulationCommandQueue.submit {
                let c = simulate_location_logged(DeviceConnectionContext.targetIPAddress,
                                                 target.latitude, target.longitude, path,
                                                 source: .teleport)
                cont.resume(returning: c)
            }
        }

        guard SimulationSession.shared.stopGeneration == stopGen else {
            stage = .idle
            return
        }

        guard code == 0 else {
            stage = .idle
            flow = .failed(title: failureTitle(code), message: failureMessage(code))
            return
        }

        // Hand the 4 s breathing hold to the Map tab's resend loop, seeded at THIS point. That loop
        // is the pause engine; from here it is the sole writer.
        NotificationCenter.default.post(
            name: .holdLocationRequested, object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        // Order mirrors `MapSelectionView.performSimulateInner`: hold, then session, then record,
        // then charge. `started()` takes the background keep-alive as part of the session, balanced
        // by the stop — Pause does not take a second, unbalanced one.
        markFrozen(at: coordinate)
        SimulationSession.shared.started()
        SimulationSession.shared.noteTeleport(to: coordinate)
        if chargeTrial, !License.shared.isLicensed { TrialManager.shared.chargeTeleport() }
        LogManager.shared.addInfoLog(String(format: "Pause: frozen at %.5f, %.5f", coordinate.latitude, coordinate.longitude))
    }

    private func markFrozen(at coordinate: CLLocationCoordinate2D) {
        frozenAt = coordinate
        // A NEW freeze restarts the clock; a re-mark of one already running keeps it, so the chip's
        // "12 min" is the age of the freeze rather than of the last thing that touched it.
        if stage != .frozen { frozenSince = Date() }
        stage = .frozen
        flow = nil
        WanderLinkAutomation.shared.noteFrozen(true)
    }

    /// Deliberately acts ONLY on `.frozen`, never on `.arming`.
    ///
    /// `beginFreeze` broadcasts a stand-down that comes straight back to our own observer, and if
    /// that reset `.arming` to `.idle` the Pause button would re-enable for the few hundred
    /// milliseconds the device write is in flight — so a second tap could start a second freeze on
    /// top of the first. An external stop landing during `.arming` is already handled where it
    /// belongs: `armFrozen` snapshots `stopGeneration` and abandons itself if it changed.
    private func clearFrozenState() {
        guard stage == .frozen else { return }
        stage = .idle
        frozenAt = nil
        frozenSince = nil
        WanderLinkAutomation.shared.noteFrozen(false)
    }

    // MARK: - Honesty about the things that quietly break a freeze

    /// Pause is the ONLY feature in the app whose entire premise is that the user walks away from
    /// the phone, which makes it the maximum-exposure case for the background-death bug the project
    /// already has a root cause for: iOS suspends the app and reclaims the socket under the DVT
    /// connection (Apple TN2277). Two settings quietly guarantee that outcome, and "I paused and it
    /// stopped working" traced to a toggle is a support ticket nobody will ever solve. So they are
    /// named, on screen, at the moment of freezing.
    var keepAliveCaveat: String? {
        if !UserDefaults.standard.bool(forKey: "keepAliveLocation") {
            return L("pause.caveat.keepalive",
                     fallback: "Background keep-alive is OFF in Settings, so this will stop when Wander is backgrounded. Turn it on for the freeze to survive you leaving.")
        }
        if CLLocationManager().authorizationStatus == .authorizedWhenInUse {
            return L("pause.caveat.always",
                     fallback: "Wander only has “While Using” location access, so the freeze may stop once you leave the app. Set it to Always in Settings.")
        }
        return nil
    }

    /// gs-loc (PoGo) mode holds differently and more weakly, and it must not be oversold: the
    /// rewriter is reactive, iOS re-queries on its own schedule, and a strong real GPS fix overrides
    /// network location entirely. Nobody should be steered here for Find My or Life360 anyway.
    var gslocCaveat: String? {
        guard GslocMode.enabled else { return nil }
        return L("pause.caveat.gsloc",
                 fallback: "You're in PoGo (gs-loc) mode, which only steers network location — a strong GPS signal overrides it. Freezing is reliable indoors, not outdoors.")
    }

    // MARK: - Helpers

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        // gs-loc mode injects through the proxy, not the dev tunnel — no pairing file needed.
        return (FileManager.default.fileExists(atPath: url.path) || GslocMode.enabled) ? url.path : nil
    }

    private func failureTitle(_ code: Int32) -> String {
        LocationSimulationOutcome.isTunnelUnreachable(code)
            ? LocationSimulationOutcome.tunnelDownTitle
            : L("pause.failed.title", fallback: "Couldn't hold your location")
    }

    /// On a dead tunnel, NAME the recovery path — do not walk it.
    ///
    /// Specifically: Pause never starts Cellular Mode. That path drops the phone into Airplane Mode
    /// for an 8 s radio-off plus a 25 s wait for signal to return, under a 120 s watchdog, with two
    /// bounces through the Shortcuts app. It is a deliberate, attended, 30–60 second procedure.
    /// Pause is a control somebody taps on their way out of the door, possibly from Control Centre;
    /// silently taking their phone off the network from that gesture would be indefensible.
    private func failureMessage(_ code: Int32) -> String {
        guard LocationSimulationOutcome.isTunnelUnreachable(code) else {
            return String(format: L("pause.failed.body",
                                    fallback: "Wander couldn't write your location to the device (error %d), so nothing was frozen. You are still on real GPS."), code)
        }
        var message = LocationSimulationOutcome.tunnelDownMessage
        if NetworkReachability.isOnCellularSnapshot {
            message += "\n\n" + L("pause.failed.cellular",
                                  fallback: "On cellular with no Wi-Fi? Use Cellular Mode on the Location tab first, then try Pause again.")
        }
        return message
    }
}
