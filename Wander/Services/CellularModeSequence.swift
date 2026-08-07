//
//  CellularModeSequence.swift
//  Wander
//
//  ══ WANDER CONDUCTS CELLULAR MODE NOW. THE SHORTCUT ONLY FLIPS THE SWITCH. ══
//
//  WHAT THIS REPLACED, AND WHY THE SWAP WAS FORCED
//  ───────────────────────────────────────────────
//  Cellular Mode used to be one Shortcut that did everything: Airplane Mode on → `Start Wander
//  Tunnel` → `Teleport to Place` → Airplane Mode off. Those middle two are Wander's own App Intents,
//  and they were App Intents for one reason — a Shortcut can WAIT on an App Intent, and a `wander://`
//  link returns instantly, so the shortcut would have had to guess a delay and would have put the
//  radio back underneath a half-built connection.
//
//  The cost of that choice was a setup step nobody could remove: an App Intent action serialises the
//  target app's identity —
//
//        AppIntentDescriptor = { TeamIdentifier, BundleIdentifier, AppIntentIdentifier, Name }
//
//  — and Wander's bundle id is DIFFERENT FOR EVERY INSTALL (`app.yellow2173.nadir6666` on the cert
//  build, `com.stik.stikdebug.<TeamID>` after a free-Apple-ID re-sign — see `WanderSigner`). A single
//  downloadable file cannot carry a value that is per-install, so the two actions imported greyed out
//  and the user had to re-pick them in the Shortcuts editor. That was step 4 of the old setup card,
//  and it was the single biggest reason people never finished setting this up.
//
//  BUILDING THE FILE ON-DEVICE WITH THE RIGHT IDENTITY DOES NOT WORK. Wander knows its own bundle id
//  (`Bundle.main.bundleIdentifier`) and its own team id (`WanderTunnel` already decodes
//  embedded.mobileprovision), so generating a correct plist is easy. Delivering it is the wall: since
//  iOS 15 a .shortcut file must be SIGNED to import, signing needs macOS's `/usr/bin/shortcuts sign`
//  or an Apple-ID-bound key, and an iPhone has neither. Apple's own string, from the shipping iOS
//  26.5 WorkflowKit: "Importing unsigned shortcut files is not supported. Please use another sharing
//  option." Anything this app writes at runtime is dead on arrival.
//
//  SO THE FIX IS TO STOP NEEDING THE IDENTITY IN THE FILE. Nothing ever forced the Shortcut to be the
//  conductor — it only had to be, because it was the thing that could wait. Invert it: the shortcut
//  becomes a dumb switch ("Wander Airplane", input "on"/"off", built-in actions only), and Wander
//  does the waiting itself, in the FOREGROUND, where it has real timeouts, real errors and a real
//  progress line instead of a Shortcut blocking on an intent with nothing on screen.
//
//  This is not merely equivalent, it is better:
//    • The file carries no bundle id, no team id, no AppIntentDescriptor. ONE signed copy is correct
//      for the cert build, for every free-sideload re-sign, and for every signature that comes later.
//    • Nothing to edit after importing. The old step 4 is gone.
//    • A failure is now something Wander can SAY. When the shortcut was the conductor, an App
//      Intent's return value was never surfaced during an unattended run, so a failed run and a
//      working one looked identical.
//    • Renaming `StartTunnelIntent` or `TeleportIntent` used to silently break every installed copy
//      of the shortcut, because `AppIntentIdentifier` is the Swift type name. It can't any more.
//
//  The cost is one extra Shortcuts hop (two short ones instead of one long one). That is a wash: the
//  old flow already bounced to Wander mid-run, because `StartTunnelIntent.openAppWhenRun` is true.
//
//  WE ASK THE RADIO, WE DO NOT ASSUME IT
//  ─────────────────────────────────────
//  iOS exposes no Airplane Mode API, and this file does not pretend otherwise. What it does have is a
//  POSITIVE precondition it can check: the sequence only ever starts from a state where
//  `NetworkReachability.isOnCellular` is true, and that flag is false in Airplane Mode. So after the
//  "on" leg returns we watch for cellular AND Wi-Fi to both go away before touching the tunnel — and
//  if they don't, we conclude the switch never flipped and say so, instead of burning a 12-second
//  tunnel timeout against a radio that is still up. This is the check the delivery investigation
//  asked for, and it is a precondition, not the stranding detector `CellularModeRun` deleted: it
//  answers "may I start?", never "is the user stranded?".
//
//  NOTHING HERE TOGGLES ANYTHING BY ITSELF. Every path begins with a tap in Wander.
//

import Foundation
import CoreLocation
import UIKit

@MainActor
final class CellularModeSequence: ObservableObject {
    static let shared = CellularModeSequence()

    // MARK: - Whether Wander puts the radio back

    /// TRUE: after the teleport lands, Wander runs the same shortcut again with "off" and the user's
    /// signal comes back on its own.
    ///
    /// ⚠️ READ `CellularModeBanner.swift` BEFORE FLIPPING THIS. That file argues, at length and
    /// correctly, that the automatic restore was removed because an interrupted run left the phone
    /// offline with no explanation, and every attempt to DETECT that from outside was unreliable.
    ///
    /// It is back on here because the thing that made detection unreliable is gone. Wander is the
    /// conductor now: it is on screen, it knows which leg it just ran, and it knows whether the
    /// network came back. The four findings in that file were all about inferring the radio's state
    /// from the outside while a Shortcut ran unattended — none of them apply to an app that issued
    /// the command itself and is watching the result. And the safety net still stands underneath:
    /// `CellularModeRun.airplaneModeLeftOn` is armed the moment the radio is CONFIRMED off and is
    /// cleared only when the restore is CONFIRMED to have worked, so any interruption anywhere in
    /// between still raises that card. Automatic restore is an improvement on top of the card, not a
    /// replacement for it.
    ///
    /// Set to `false` and the sequence stops after the teleport, leaving the card to ask the user to
    /// flip the switch back — the exact behaviour `CellularModeBanner` describes. Nothing else needs
    /// to change.
    static let restoresRadioAutomatically = true

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        /// Handed off to Shortcuts for the "on" leg; waiting to be brought back.
        case switchingRadioOff
        /// Back in Wander, watching the network path until the radio has actually gone quiet.
        case confirmingRadioOff
        /// Doing the real work in-process: tunnel up, then teleport.
        case connecting
        /// Handed off to Shortcuts for the "off" leg; waiting to be brought back.
        case restoringRadio
    }

    /// What went wrong, in a form a view can put in front of the user. `offerSetup` is the difference
    /// between "something failed" and "the shortcut isn't there" — only the second one should send
    /// somebody back to the setup card.
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
        let offerSetup: Bool
    }

    @Published private(set) var phase: Phase = .idle
    /// One line of plain progress, shown while the sequence runs. Nil when idle.
    @Published private(set) var statusText: String?
    /// Set on any failure. A view binds an alert to this and clears it on dismiss.
    @Published var failure: Failure?

    var isRunning: Bool { phase != .idle }

    // MARK: - Private state

    private var target: CLLocationCoordinate2D?
    /// True once we have CONFIRMED the radio went off — the only thing that authorises a restore.
    private var radioIsOff = false
    /// Carried from the work phase to the end, so the restore runs even when the teleport failed and
    /// the user is still told what happened.
    private var pendingOutcome: WanderLocationIntent.TeleportOutcome?
    /// Set when we hand off to Shortcuts; the didBecomeActive handler ignores anything that arrives
    /// before we have actually left, so a same-runloop activation can't advance the sequence.
    private var hasLeftForShortcuts = false
    /// One name-fallback retry per RUN, not per leg. Bounds `retryLegUnderFilenameSpelling` to a
    /// single extra Shortcuts flash: if the filename spelling misses too, the shortcut really is not
    /// there under either name and the run should fail onto the setup card rather than keep bouncing.
    private var hasRetriedUnderFilenameSpelling = false
    private var watchdog: Task<Void, Never>?
    /// Bumped by every `start` and every `reset`, and re-checked after each `await`.
    ///
    /// The teleport takes tens of seconds and cannot be interrupted once it is in flight, so Cancel
    /// (and any failure that resets us) has to be able to ABANDON a run rather than stop it. Without
    /// this counter, a Cancel during the tunnel/teleport step would be followed, seconds later, by
    /// that step's continuation cheerfully handing off to Shortcuts to toggle the radio again — a
    /// cancelled run restarting itself, which is the worst possible reading of a Cancel button.
    private var generation = 0

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Entry point

    /// Run Cellular Mode for `coordinate`.
    ///
    /// The paywall gate is deliberately NOT here: callers already ask `CellularModeRun.isAllowedToStart`
    /// so they can present the paywall, and `WanderLocationIntent.teleport` asks it again before it
    /// charges anything. Two gates on the same predicate, no third opinion.
    func start(latitude: Double, longitude: Double) {
        // Re-entrancy: a second tap while a run is in flight would hand off to Shortcuts twice and
        // leave two state machines racing for one radio.
        guard phase == .idle else { return }

        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coord) else { return }
        generation &+= 1
        target = coord
        radioIsOff = false
        pendingOutcome = nil
        failure = nil
        // So the recovery card's "Try again" has a destination, exactly as the old hand-off did.
        CellularModeRun.shared.noteLaunchedFromApp(latitude: latitude, longitude: longitude)

        // ON WI-FI THERE IS NOTHING TO FIX. lockdownd only refuses the tunnel on cellular-with-no-
        // Wi-Fi, so an airplane cycle here would drop somebody's connection to buy nothing. The old
        // shortcut carried two `Get Network Details` actions to work this out for itself; Wander
        // already knows, from the same NWPathMonitor read the button is gated on.
        if NetworkReachability.shared.hasWiFi {
            LogManager.shared.addInfoLog("Cellular Mode: Wi-Fi present, skipping the Airplane Mode cycle")
            Task { await performWork() }
            return
        }

        guard ShortcutRunner.shortcutsAppInstalled else {
            fail(title: L("cellular.fail.noshortcuts.title", fallback: "Shortcuts isn't available"),
                 message: L("cellular.fail.noshortcuts.body",
                            fallback: "Cellular Mode needs the Shortcuts app, because iOS gives an app no way to touch Airplane Mode. Reinstall Shortcuts from the App Store, or turn Airplane Mode on yourself, teleport, then turn it back off."),
                 offerSetup: false)
            return
        }
        guard ShortcutRunner.airplaneReady else {
            fail(title: L("cellular.fail.notsetup.title", fallback: "Cellular Mode isn't set up yet"),
                 message: L("cellular.fail.notsetup.body",
                            fallback: "Wander needs its one-action “\(ShortcutRunner.airplaneName)” shortcut installed before it can flip Airplane Mode for you."),
                 offerSetup: true)
            return
        }

        handOff(to: true,
                phase: .switchingRadioOff,
                status: L("cellular.status.radiooff",
                          fallback: "Switching Airplane Mode on…"))
    }

    /// Give up on a run in flight and put the user back in charge. Safe at any point: it never
    /// touches the radio, and it deliberately leaves `CellularModeRun.airplaneModeLeftOn` exactly as
    /// it found it, so a cancel after the radio went off still raises the card that explains it.
    func cancel() {
        guard phase != .idle else { return }
        LogManager.shared.addInfoLog("Cellular Mode: cancelled by the user at \(phase)")
        reset()
    }

    // MARK: - Hand-off

    /// Shortcuts reported x-error: nothing in this library is called "Wander Airplane". Re-run the
    /// SAME leg under the filename spelling ("wander-airplane") before we believe it is missing, so a
    /// library that still holds the file under its old published name keeps working untouched.
    ///
    /// Driven by the real callback, never by a timer — `MainTabView` calls this from
    /// `wander://airplane-missing`. It lives here rather than in `ShortcutRunner` because a blind
    /// re-fire would race this sequence's own lifecycle: the x-error URL brings Wander to the front,
    /// and `appDidBecomeActive` may already have moved us into `.confirmingRadioOff`, where an 8 s
    /// poll is counting down against a radio that was never touched. Bumping `generation` abandons
    /// that poll, and `handOff` clears `hasLeftForShortcuts`, so the return from the FAILED hand-off
    /// cannot advance anything either. Both orderings of the two callbacks end in the same state.
    ///
    /// Returns false when there is no leg to retry or the retry has already been spent — the second
    /// miss then falls through to the ordinary radio check, which fails with `offerSetup: true` and
    /// puts the setup card in front of the user rather than failing silently.
    @discardableResult
    func retryLegUnderFilenameSpelling() -> Bool {
        let on: Bool
        switch phase {
        case .switchingRadioOff, .confirmingRadioOff: on = true
        case .restoringRadio: on = false
        case .idle, .connecting: return false
        }
        guard !hasRetriedUnderFilenameSpelling else { return false }
        hasRetriedUnderFilenameSpelling = true

        let alternate = ShortcutRunner.filenameSpelling(of: ShortcutRunner.airplaneName)
        LogManager.shared.addInfoLog(
            "Cellular Mode: “\(ShortcutRunner.airplaneName)” not found — retrying as “\(alternate)”")
        generation &+= 1
        handOff(to: on,
                phase: on ? .switchingRadioOff : .restoringRadio,
                status: on
                    ? L("cellular.status.radiooff", fallback: "Switching Airplane Mode on…")
                    : L("cellular.status.radioback", fallback: "Switching Airplane Mode back off…"),
                name: alternate)
        return true
    }

    private func handOff(to on: Bool, phase newPhase: Phase, status: String,
                         name: String = ShortcutRunner.airplaneName) {
        phase = newPhase
        statusText = status
        hasLeftForShortcuts = false
        startWatchdog()
        ShortcutRunner.runAirplane(on: on, name: name) { [weak self] in
            // iOS refused to open Shortcuts at all. WHICH LEG THIS WAS CHANGES THE ADVICE ENTIRELY:
            // on the way out nothing has happened yet and the user's signal is untouched; on the way
            // back the radio is already off and the only thing that matters is telling them so.
            Task { @MainActor in
                self?.fail(title: L("cellular.fail.handoff.title", fallback: "Couldn't open Shortcuts"),
                           message: on
                               ? L("cellular.fail.handoff.out",
                                   fallback: "iOS wouldn't hand over to the Shortcuts app, so nothing happened and your signal was not touched. Try again, or turn Airplane Mode on yourself, teleport, then turn it back off.")
                               : L("cellular.fail.handoff.back",
                                   fallback: "Airplane Mode is still ON and iOS wouldn't hand back to Shortcuts to switch it off. Swipe down from the top-right corner and tap the airplane to get your signal back. Your location stays where you set it."),
                           offerSetup: false)
            }
        }
    }

    // MARK: - Lifecycle

    @objc private func appWillResignActive() {
        guard phase == .switchingRadioOff || phase == .restoringRadio else { return }
        hasLeftForShortcuts = true
    }

    @objc private func appDidBecomeActive() {
        // Only a return from a hand-off advances the sequence. Without this, a notification that
        // fires in the same run loop as the `open` call (or a plain app-switch by the user) would
        // step the state machine forward while Shortcuts had not run at all.
        guard hasLeftForShortcuts else { return }
        hasLeftForShortcuts = false
        watchdog?.cancel()
        switch phase {
        case .switchingRadioOff:
            Task { await confirmRadioOffThenWork() }
        case .restoringRadio:
            Task { await finishAfterRestore() }
        default:
            break
        }
    }

    /// A hand-off that never comes back. Counts FOREGROUND time only — `Task.sleep` pauses while the
    /// app is suspended — which is exactly right: while the user is looking at Shortcuts we are
    /// happy to wait, and the clock only runs once we are on screen again with nothing happening.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.phase == .switchingRadioOff || self.phase == .restoringRadio else { return }
                self.fail(title: L("cellular.fail.stalled.title", fallback: "Cellular Mode stalled"),
                          message: L("cellular.fail.stalled.body",
                                     fallback: "The Shortcuts hand-off never came back. Check Airplane Mode yourself — if it's on, switch it off — and try again."),
                          offerSetup: false)
            }
        }
    }

    // MARK: - Step 1 → 2: did the radio actually go off?

    private func confirmRadioOffThenWork() async {
        let gen = generation
        phase = .confirmingRadioOff
        statusText = L("cellular.status.confirming", fallback: "Waiting for the radio to go quiet…")

        // 8 s. Dropping the interfaces is fast — the shortcut already sat through its own 4 s settle —
        // and every extra second here is spent with the radio off for nothing.
        let quiet = await waitForNetwork(gone: true, timeout: 8)
        guard gen == generation else { return }   // cancelled/abandoned while we watched
        if quiet {
            radioIsOff = true
            // TRUE BY OBSERVATION, not by inference: we asked for Airplane Mode on, and both
            // transports then went away. Persisted immediately, because the case this exists for is a
            // run that dies here and an app that gets force-quit.
            CellularModeRun.shared.noteAirplaneModeTurnedOn()
            LogManager.shared.addInfoLog("Cellular Mode: radio confirmed off, bringing the tunnel up")
            await performWork()
            return
        }

        // The radio is still up, so the shortcut did not do its job — it is missing, renamed, was
        // cancelled at the confirmation prompt, or Shortcuts errored. Nothing was turned off, so
        // there is nothing to turn back on: stop, say so, and do NOT arm the airplane card for a
        // switch that never moved.
        LogManager.shared.addInfoLog("Cellular Mode: Airplane Mode never took effect — aborting before the tunnel")
        // Self-heal the installed flag the same way the rest of the pack does, so the setup card
        // comes back instead of a button that fails the same way forever.
        ShortcutRunner.airplaneReady = false
        fail(title: L("cellular.fail.radio.title", fallback: "Airplane Mode didn't switch on"),
             message: L("cellular.fail.radio.body",
                        fallback: "Your signal is still up, so Wander stopped rather than start a tunnel that iOS would refuse. Usually the “\(ShortcutRunner.airplaneName)” shortcut is missing, renamed, or was cancelled. Set it up again — or turn Airplane Mode on yourself, teleport, then turn it back off."),
             offerSetup: true)
    }

    // MARK: - Step 2: the work Wander used to ask a Shortcut to wait for

    /// The two App Intent actions that used to live in the shortcut, run here instead — in the
    /// foreground, with real waits and a real error. `WanderLocationIntent.teleport` is the SAME code
    /// path `TeleportIntent` runs, including bringing the tunnel up, so this is a change of caller,
    /// not a second implementation.
    private func performWork() async {
        guard let coord = target else { reset(); return }
        let gen = generation
        phase = .connecting
        statusText = L("cellular.status.connecting", fallback: "Connecting the tunnel and setting your location…")

        let name = WanderLocationIntent.recentsName(
            for: String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                        coord.latitude, coord.longitude))
        let outcome = await WanderLocationIntent.teleport(to: coord, name: name)
        // Cancelled while the teleport was in flight. The teleport itself could not be stopped — and
        // its own bookkeeping has already run, which is correct, because it really did happen — but
        // this sequence must not go on to toggle the radio for a run the user walked away from.
        guard gen == generation else { return }
        pendingOutcome = outcome

        // THE RESTORE RUNS EVEN WHEN THE TELEPORT FAILED. A failure is not a reason to leave somebody
        // without a phone; the error is reported after the signal is back.
        guard radioIsOff, Self.restoresRadioAutomatically else {
            finish()
            return
        }
        handOff(to: false,
                phase: .restoringRadio,
                status: L("cellular.status.radioback", fallback: "Switching Airplane Mode back off…"))
    }

    // MARK: - Step 3: signal back, then report

    private func finishAfterRestore() async {
        let gen = generation
        statusText = L("cellular.status.waitingsignal", fallback: "Waiting for your signal…")
        // 25 s, not 8. Coming BACK is a different physical process from going away: the modem has to
        // re-attach to the carrier and re-register, which routinely takes ten seconds or more. Using
        // the tight outbound budget here would raise "your signal didn't come back" at people whose
        // signal was simply still on its way, which is exactly the kind of hedged, probably-wrong
        // warning `CellularModeBanner` exists to stop us shipping.
        let back = await waitForNetwork(gone: false, timeout: 25)
        guard gen == generation else { return }
        if back {
            // Confirmed from the other side: a transport is back. This is the ONLY thing that
            // retires the airplane card automatically — see `CellularModeRun.dismissAirplaneNotice`,
            // whose usual caller is the user's own tap. Calling it here is not a guess: Wander issued
            // the "off" command itself and then watched the network return.
            CellularModeRun.shared.dismissAirplaneNotice()
            LogManager.shared.addInfoLog("Cellular Mode: signal confirmed back")
        } else {
            // Leave the card up. It is the honest outcome: we asked for the radio back and cannot
            // see it, so the user is the one who has to check.
            LogManager.shared.addInfoLog("Cellular Mode: signal did NOT come back — leaving the Airplane Mode card up")
        }
        finish()
    }

    private func finish() {
        let outcome = pendingOutcome
        reset()
        switch outcome {
        case .none, .some(.ok):
            break
        case .some(.notLicensed):
            fail(title: L("cellular.fail.trial.title", fallback: "Today's free teleport is used up"),
                 message: L("cellular.fail.trial.body",
                            fallback: "Your signal is back and nothing was changed. Go Pro for unlimited teleports."),
                 offerSetup: false)
        case .some(.failed):
            fail(title: L("cellular.fail.teleport.title", fallback: "The teleport didn't take"),
                 message: L("cellular.fail.teleport.body",
                            fallback: "Airplane Mode did its part, but the tunnel or the teleport failed — most often a missing pairing file (Settings → Pairing) or a tunnel that couldn't claim iOS's single VPN slot. Trying again usually does it."),
                 offerSetup: false)
        }
    }

    // MARK: - Helpers

    /// Poll the app's existing NWPathMonitor flags until the transports are gone (or back).
    ///
    /// Reads `isOnCellular` and `hasWiFi` rather than `isOnline`, on purpose: `isOnline` is TRUE in
    /// Airplane Mode whenever Wander's own loopback tunnel is up (it is a satisfied path with no
    /// internet — see `NetworkReachability.hasInternet`), so it would answer the wrong question. The
    /// two transport flags read the UNDERLYING interface, which a utun cannot fake.
    private func waitForNetwork(gone: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let r = NetworkReachability.shared
            let quiet = !r.isOnCellular && !r.hasWiFi
            if quiet == gone { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func fail(title: String, message: String, offerSetup: Bool) {
        reset()
        failure = Failure(title: title, message: message, offerSetup: offerSetup)
    }

    private func reset() {
        // Anything still awaiting on behalf of the run we are ending now belongs to a generation that
        // no longer exists, and will bail at its next checkpoint.
        generation &+= 1
        watchdog?.cancel()
        watchdog = nil
        phase = .idle
        statusText = nil
        hasLeftForShortcuts = false
        hasRetriedUnderFilenameSpelling = false
        target = nil
        radioIsOff = false
        pendingOutcome = nil
    }
}
