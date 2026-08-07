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
//  becomes a dumb switch (one file, input "on"/"off", built-in actions only), and Wander
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
//  THE SHORTCUT NOW SAYS WHICH FILE IT IS, AND NOTHING RUNS UNTIL IT HAS
//  ────────────────────────────────────────────────────────────────────
//  The one-action file is published as "Wander Cellular Mode" — the same name as the feature, and the
//  same name the OLD all-in-one file was published under for a few hours on 2026-08-06. Shortcuts is
//  invoked by name and does not let an app read a shortcut's contents, so if both files are in one
//  library, Wander asking for that name may reach either.
//
//  A run against the old file would be genuinely dangerous. It ignores our input, runs its own
//  sequence, and turns Airplane Mode on. Its restore step is real (unconditional, on every path — this
//  was checked in the file, not assumed), but `StartTunnelIntent.openAppWhenRun` foregrounds Wander in
//  the middle of it, and a Shortcuts run that iOS suspends before its last actions never reaches that
//  restore. The radio stays off.
//
//  So the file identifies itself. Its last action opens `wander://airplane-ok`; the old file's last
//  action opens `wander://cellular-done`. Disjoint, and both originate INSIDE the file, so neither can
//  be forged by the x-success callback Shortcuts fires for whatever it happened to run.
//
//  Three things follow, and all three are load-bearing:
//    1. `start()` refuses to run at all until `ShortcutRunner.cellularModeVerified` is true, and only
//       an `airplane-ok` from a run Wander itself invoked by name sets that. A user who did not delete
//       the old file therefore cannot arm the feature — it fails CLOSED, by construction.
//    2. The radio check is no longer sufficient on its own. The old file also turns the radio off, so
//       "both transports went away" cannot tell the two apart; the leg must ALSO have said
//       `airplane-ok` before we build a tunnel on top of it.
//    3. When the wrong file answers, Wander does not merely explain. It runs the name again with
//       "off", which restores the radio under EITHER file: ours takes its Otherwise branch, and the
//       old one cannot re-enter its Airplane-Mode-on branch because that branch is gated on reading a
//       cellular carrier name, and there is no carrier to read while the radio is off. The card that
//       spells out the Control Center gesture stays up underneath as the guarantee.
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
        /// Handed off to Shortcuts with "off" purely to find out WHICH file answers to the name.
        /// Deliberately the harmless input: on the shipped file this switches Airplane Mode off while
        /// it is already off, i.e. nothing happens at all.
        case verifying
        /// Handed off to Shortcuts for the "on" leg; waiting to be brought back.
        case switchingRadioOff
        /// Back in Wander, watching the network path until the radio has actually gone quiet.
        case confirmingRadioOff
        /// Doing the real work in-process: tunnel up, then teleport.
        case connecting
        /// Handed off to Shortcuts for the "off" leg; waiting to be brought back.
        case restoringRadio
        /// Something turned the radio off that we did not authorise (the wrong file answered to the
        /// name). Handed off with "off" to get the signal back; the recovery card is already up.
        case recoveringRadio
    }

    /// What a verification run concluded, for the setup card to show in place of its old optimistic
    /// "I've added it" tick.
    enum VerificationResult: Equatable {
        /// `wander://airplane-ok` came back: the name resolves to the shipped one-action file.
        case verified
        /// `wander://cellular-done`, or the radio went off when we asked for it to go off — either way
        /// the name resolved to the OLD all-in-one file and it must be deleted.
        case legacyShortcut
        /// Shortcuts has nothing by that name, under either spelling.
        case notFound
        /// It ran, but never identified itself. Almost always an older copy of our own file, from
        /// before it learned to say `airplane-ok` — re-adding it fixes that.
        case unrecognised
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
    /// The verdict of the last `verify()`. The setup card reads it; nothing else does.
    @Published var verificationResult: VerificationResult?

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
    /// `wander://airplane-ok` arrived for the leg currently in flight — the shipped one-action file
    /// saying, from inside itself, that it is the thing that just ran. Cleared at every hand-off, so
    /// it can never be carried over from an earlier leg.
    private var sawAirplaneOk = false
    /// `wander://cellular-done` arrived: the OLD all-in-one file answered to the name we asked for.
    /// Positive proof of the collision, not an inference.
    private var sawLegacyShortcut = false
    /// One recovery hand-off per run. Without this a recovery that itself reaches the wrong file could
    /// bounce between Wander and Shortcuts indefinitely, which is a worse experience than the card.
    private var hasAttemptedRecovery = false
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
        hasAttemptedRecovery = false

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

        // THE GATE, AND IT FAILS CLOSED ON PURPOSE.
        //
        // The previous version of this comment argued the opposite — try it and let the evidence
        // arrive — and that was right while the only risk of guessing wrong was a wasted Shortcuts
        // flash. It is not right any more. "Wander Cellular Mode" is a name the OLD all-in-one file
        // also answers to, and a run that reaches that file turns the radio off and may never turn it
        // back on. Guessing now costs somebody their signal, so we do not guess: we require the file
        // to have identified itself, from inside itself, on a run Wander invoked by name.
        //
        // The flag cannot be set by a button, cannot be inherited from the pre-rename install, and is
        // cleared by anything that contradicts it — so its false value routes to the setup card, where
        // one tap runs the harmless "off" handshake that either arms the feature or names the problem.
        guard ShortcutRunner.cellularModeVerified,
              !CellularModeRun.shared.legacyShortcutDetected else {
            fail(title: L("cellular.fail.unverified.title", fallback: "Check the shortcut first"),
                 message: L("cellular.fail.unverified.body",
                            fallback: "Wander runs shortcuts by name and can't see inside one, and an older Wander shortcut answers to this same name — running it by accident would turn Airplane Mode on and might not turn it back off. Open setup and tap Check the shortcut: it takes a second and nothing is switched."),
                 offerSetup: true)
            return
        }

        handOff(to: true,
                phase: .switchingRadioOff,
                status: L("cellular.status.radiooff",
                          fallback: "Switching Airplane Mode on…"))
    }

    // MARK: - Verification
    //
    // WHY THE HANDSHAKE ASKS FOR "off", AND WHY THAT IS THE SAFE INPUT. On the shipped one-action file
    // "off" takes the Otherwise branch and sets Airplane Mode off while it is already off — a no-op, on
    // a phone whose radio is up. Nothing happens and Wander gets its proof.
    //
    // BE HONEST ABOUT THE OTHER FILE. The old all-in-one ignores its input entirely, so if IT answers
    // this handshake on mobile data it will turn the radio off regardless of what we asked for. That is
    // not free, and it is not hidden: it happens at a moment the user chose, on a screen that is about
    // this exact problem, with the phone in their hand — and it happens at most ONCE, because the same
    // run that costs them six seconds of signal is the run that identifies the file, latches
    // `legacyShortcutDetected`, and refuses the name from then on. Wander also immediately runs the
    // name again with "off" to bring the radio back, and puts the Control Center gesture on screen.
    //
    // The alternative — verify silently on the first real teleport instead — pays the same cost at a
    // moment the user did not choose, with no explanation attached, and pays it again on every run.

    /// Find out which file answers to the name, without doing anything else.
    func verify() {
        guard phase == .idle else { return }
        generation &+= 1
        failure = nil
        verificationResult = nil
        target = nil
        radioIsOff = false
        hasAttemptedRecovery = false
        hasRetriedUnderFilenameSpelling = false

        guard ShortcutRunner.shortcutsAppInstalled else {
            verificationResult = .notFound
            return
        }
        handOff(to: false,
                phase: .verifying,
                status: L("cellular.status.verifying",
                          fallback: "Checking which shortcut answers…"))
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

    /// Shortcuts reported x-error: nothing in this library is called "Wander Cellular Mode". Re-run
    /// the SAME leg under the filename spelling ("wander-cellular-mode") before we believe it is
    /// missing, so a library that holds the file under its kebab-cased filename keeps working.
    ///
    /// ⚠️ THAT SECOND SPELLING IS ALSO THE OLD ALL-IN-ONE FILE'S PUBLISHED FILENAME, so this retry can
    /// reach it. Safe only because a retry proves nothing on its own: whatever answers still has to
    /// send `wander://airplane-ok` before anything is armed or any tunnel is built.
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
        let retryPhase: Phase
        let status: String
        switch phase {
        case .switchingRadioOff, .confirmingRadioOff:
            on = true
            retryPhase = .switchingRadioOff
            status = L("cellular.status.radiooff", fallback: "Switching Airplane Mode on…")
        case .restoringRadio:
            on = false
            retryPhase = .restoringRadio
            status = L("cellular.status.radioback", fallback: "Switching Airplane Mode back off…")
        case .verifying:
            on = false
            retryPhase = .verifying
            status = L("cellular.status.verifying", fallback: "Checking which shortcut answers…")
        case .recoveringRadio:
            on = false
            retryPhase = .recoveringRadio
            status = L("cellular.status.recovering", fallback: "Getting your signal back…")
        case .idle, .connecting:
            return false
        }
        guard !hasRetriedUnderFilenameSpelling else {
            // Nothing left to try. A verification that gets here has its answer: no shortcut of either
            // spelling exists, which is a legitimate verdict and must not be left hanging on the 10 s
            // timeout below.
            if retryPhase == .verifying { concludeVerification(.notFound) }
            return false
        }
        hasRetriedUnderFilenameSpelling = true

        let alternate = ShortcutRunner.filenameSpelling(of: ShortcutRunner.cellularModeName)
        LogManager.shared.addInfoLog(
            "Cellular Mode: “\(ShortcutRunner.cellularModeName)” not found — retrying as “\(alternate)”")
        generation &+= 1
        handOff(to: on, phase: retryPhase, status: status, name: alternate)
        return true
    }

    private func handOff(to on: Bool, phase newPhase: Phase, status: String,
                         name: String = ShortcutRunner.cellularModeName) {
        phase = newPhase
        statusText = status
        hasLeftForShortcuts = false
        // Per LEG, never per run: the proof has to be re-earned by whatever is about to run, or a
        // healthy first leg would vouch for a second leg that reached a different file.
        sawAirplaneOk = false
        sawLegacyShortcut = false
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

    // MARK: - Which file just ran
    //
    // Both of these arrive from `MainTabView.handleURL`, fired by the shortcut's own last action rather
    // than by the x-callback Shortcuts attaches. That distinction is the entire security of this
    // scheme: x-success reports "something finished", the URL inside the file reports "I am the file
    // that finished".

    /// `wander://airplane-ok` — the shipped one-action file. Only a run WE invoked by name can turn
    /// this into `cellularModeVerified`: a hand-run out of the Shortcuts app proves the file exists but
    /// says nothing about what it is CALLED, and the name is the only thing in question.
    func noteAirplaneShortcutAnswered() {
        switch phase {
        case .verifying, .switchingRadioOff, .confirmingRadioOff, .restoringRadio:
            sawAirplaneOk = true
            ShortcutRunner.cellularModeVerified = true
        case .idle, .connecting, .recoveringRadio:
            // NOT during a recovery. We only ever recover because something we did not authorise took
            // the radio off, and the right file answering the recovery hand-off does not retract that
            // — the collision is between TWO files and iOS may pick either one next time. The sticky
            // `legacyShortcutDetected` is cleared by a clean verification and by nothing else.
            break
        }
    }

    /// `wander://cellular-done` — the OLD all-in-one file. Nothing Wander ships opens this any more, so
    /// receiving it is positive proof that the name resolved to the wrong file.
    ///
    /// Handled even when idle, because a user can reach the old file by hand and the card explaining
    /// what to delete is worth showing either way.
    func noteLegacyShortcutAnswered() {
        LogManager.shared.addInfoLog("Cellular Mode: the OLD all-in-one shortcut answered — name collision")
        sawLegacyShortcut = true
        ShortcutRunner.cellularModeVerified = false
        CellularModeRun.shared.noteLegacyShortcutDetected()
    }

    // MARK: - Lifecycle

    @objc private func appWillResignActive() {
        switch phase {
        case .verifying, .switchingRadioOff, .restoringRadio, .recoveringRadio:
            hasLeftForShortcuts = true
        case .idle, .confirmingRadioOff, .connecting:
            break
        }
    }

    @objc private func appDidBecomeActive() {
        // Only a return from a hand-off advances the sequence. Without this, a notification that
        // fires in the same run loop as the `open` call (or a plain app-switch by the user) would
        // step the state machine forward while Shortcuts had not run at all.
        guard hasLeftForShortcuts else { return }
        hasLeftForShortcuts = false
        watchdog?.cancel()
        switch phase {
        case .verifying:
            Task { await finishVerification() }
        case .switchingRadioOff:
            Task { await confirmRadioOffThenWork() }
        case .restoringRadio:
            Task { await finishAfterRestore() }
        case .recoveringRadio:
            Task { await finishRecovery() }
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
                switch self.phase {
                case .verifying:
                    self.concludeVerification(.unrecognised)
                case .switchingRadioOff, .restoringRadio, .recoveringRadio:
                    self.fail(title: L("cellular.fail.stalled.title", fallback: "Cellular Mode stalled"),
                              message: L("cellular.fail.stalled.body",
                                         fallback: "The Shortcuts hand-off never came back. Check Airplane Mode yourself — swipe down from the top-right corner and tap the airplane if it's on — and try again."),
                              offerSetup: false)
                case .idle, .confirmingRadioOff, .connecting:
                    break
                }
            }
        }
    }

    // MARK: - Step 0: which file answers to the name?

    private func finishVerification() async {
        let gen = generation
        statusText = L("cellular.status.verifying", fallback: "Checking which shortcut answers…")

        // 10 s, polled: the file's own `Open URL` and Shortcuts' x-success land within a second or two
        // of the app coming forward, but the ORDER of a URL delivery against `didBecomeActive` is not
        // guaranteed, so deciding on the first run loop would false-negative a perfectly good file.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard gen == generation else { return }
            // Checked BEFORE the good news: if both signals somehow arrive, the one that means "the
            // radio may be off" has to win.
            if sawLegacyShortcut { await handleWrongFileAnsweredDuringVerification(); return }
            let r = NetworkReachability.shared
            if !r.isOnCellular && !r.hasWiFi {
                // We asked for Airplane Mode OFF and both transports vanished. Our file cannot do that
                // on any input, so something else ran — and whatever it was, the user's signal is gone
                // and getting it back is now the only thing that matters.
                LogManager.shared.addInfoLog("Cellular Mode: the radio went OFF during a check that asked for OFF")
                noteLegacyShortcutAnswered()
                await handleWrongFileAnsweredDuringVerification()
                return
            }
            if sawAirplaneOk { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard gen == generation else { return }
        concludeVerification(sawAirplaneOk ? .verified : .unrecognised)
    }

    /// The wrong file answered a verification. The radio is off (or on its way off) and the user did
    /// not ask for that, so: say so permanently, arm the card that carries the manual gesture, and try
    /// the one recovery that is safe under BOTH files.
    private func handleWrongFileAnsweredDuringVerification() async {
        // TRUE BY OBSERVATION where we saw the transports go; asserted-then-retired where we only saw
        // the callback. Arming it in both cases is the conservative direction: a card that says
        // "Airplane Mode is on" on a phone that has signal is dismissed in one tap, and the reverse
        // mistake leaves somebody offline with nothing on screen.
        CellularModeRun.shared.noteAirplaneModeTurnedOn()
        verificationResult = .legacyShortcut
        beginRecovery()
    }

    private func concludeVerification(_ result: VerificationResult) {
        reset()
        verificationResult = result
        switch result {
        case .verified:
            LogManager.shared.addInfoLog("Cellular Mode: shortcut verified — the name resolves to the one-action file")
            // The one thing that retires a collision: we asked for the name, and the right file
            // answered. Anything short of that leaves the warning standing.
            CellularModeRun.shared.clearLegacyShortcutNotice()
        case .legacyShortcut, .notFound, .unrecognised:
            ShortcutRunner.cellularModeVerified = false
        }
    }

    // MARK: - Getting the radio back after the wrong file answered

    /// Run the name again with "off". SAFE UNDER EITHER FILE while the radio is down, and this is the
    /// reason a recovery exists at all rather than only a card:
    ///   • the shipped file takes its Otherwise branch on any input that is not "on", and switches
    ///     Airplane Mode off;
    ///   • the old all-in-one gates its Airplane-Mode-ON branch on reading a cellular carrier name, and
    ///     in Airplane Mode there is no carrier to read — so it falls to its unconditional tail, which
    ///     is `Set Airplane Mode → Off`.
    /// Neither file can turn the radio ON from here. Verified by reading both files' actions, not
    /// assumed; if either is ever edited, re-check this claim before trusting this path again.
    private func beginRecovery() {
        guard !hasAttemptedRecovery else {
            // One recovery per run is the bound, but "we already tried" must never leave the user
            // staring at a spinner with no signal. Say the thing that always works instead.
            LogManager.shared.addInfoLog("Cellular Mode: recovery already spent — falling back to the manual card")
            reset()
            failure = Failure(
                title: L("cellular.fail.collision.stuck.title", fallback: "Turn Airplane Mode off yourself"),
                message: L("cellular.fail.collision.stuck.body",
                           fallback: "The older shortcut of the same name switched Airplane Mode on and Wander can't see your signal come back. Swipe down from the top-right corner of the screen and tap the airplane icon to turn it off. Then open Shortcuts and delete the OLD “\(ShortcutRunner.cellularModeName)” — the long one with Wander actions inside it."),
                offerSetup: false)
            return
        }
        hasAttemptedRecovery = true
        generation &+= 1
        hasRetriedUnderFilenameSpelling = false
        handOff(to: false,
                phase: .recoveringRadio,
                status: L("cellular.status.recovering", fallback: "Getting your signal back…"))
    }

    private func finishRecovery() async {
        let gen = generation
        statusText = L("cellular.status.waitingsignal", fallback: "Waiting for your signal…")
        let back = await waitForNetwork(gone: false, timeout: 25)
        guard gen == generation else { return }
        if back {
            CellularModeRun.shared.dismissAirplaneNotice()
            LogManager.shared.addInfoLog("Cellular Mode: signal confirmed back after the collision recovery")
        } else {
            LogManager.shared.addInfoLog("Cellular Mode: signal did NOT come back after the collision recovery")
        }
        reset()
        // Reported either way, because the collision itself has to be named — the user has two
        // shortcuts sharing one name and nothing works properly until the old one is gone.
        failure = Failure(
            title: back
                ? L("cellular.fail.collision.title", fallback: "That was the old shortcut")
                : L("cellular.fail.collision.stuck.title", fallback: "Turn Airplane Mode off yourself"),
            message: back
                ? L("cellular.fail.collision.body",
                    fallback: "Two shortcuts on this phone are called “\(ShortcutRunner.cellularModeName)”, and iOS handed Wander the older one, which switched Airplane Mode on by itself. Your signal is back. Open Shortcuts, delete the OLD one — it is the long one with Wander actions inside it — then check again here.")
                : L("cellular.fail.collision.stuck.body",
                    fallback: "The older shortcut of the same name switched Airplane Mode on and Wander can't see your signal come back. Swipe down from the top-right corner of the screen and tap the airplane icon to turn it off. Then open Shortcuts and delete the OLD “\(ShortcutRunner.cellularModeName)” — the long one with Wander actions inside it."),
            offerSetup: back)
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

            // THE RADIO CHECK IS NO LONGER SUFFICIENT ON ITS OWN. It used to be the whole test, back
            // when only one file could have run. The old all-in-one turns the radio off too, so a
            // quiet interface says "some Airplane Mode shortcut ran", not "OUR shortcut ran". Before
            // building a tunnel on top of it, wait for the file to say which one it is.
            //
            // A few extra seconds, not a fresh budget: the callback normally beats the 8 s poll above
            // and this loop exits immediately.
            let idDeadline = Date().addingTimeInterval(4)
            while !sawAirplaneOk && !sawLegacyShortcut && Date() < idDeadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard gen == generation else { return }
            }
            guard gen == generation else { return }
            if sawLegacyShortcut || !sawAirplaneOk {
                if !sawLegacyShortcut {
                    LogManager.shared.addInfoLog(
                        "Cellular Mode: the radio went off but nothing said airplane-ok — refusing to build on an unidentified shortcut")
                    ShortcutRunner.cellularModeVerified = false
                }
                // The radio is already off, so the only useful thing left is to put it back and say
                // what happened. Deliberately BEFORE the tunnel: half a minute of connecting is half a
                // minute of no signal bought for a run we already know we cannot trust.
                beginRecovery()
                return
            }

            LogManager.shared.addInfoLog("Cellular Mode: radio confirmed off, bringing the tunnel up")
            await performWork()
            return
        }

        // The radio is still up, so the shortcut did not do its job — it is missing, renamed, was
        // cancelled at the confirmation prompt, or Shortcuts errored. Nothing was turned off, so
        // there is nothing to turn back on: stop, say so, and do NOT arm the airplane card for a
        // switch that never moved.
        LogManager.shared.addInfoLog("Cellular Mode: Airplane Mode never took effect — aborting before the tunnel")
        // Self-heal, so the setup card comes back instead of a button that fails the same way forever.
        // There is no longer a second shortcut to fall back to — the old all-in-one has been retired,
        // and routing to it is precisely what the identity check above exists to prevent.
        ShortcutRunner.cellularModeVerified = false

        fail(title: L("cellular.fail.radio.title", fallback: "Airplane Mode didn't switch on"),
             message: L("cellular.fail.radio.body",
                        fallback: "Your signal is still up, so Wander stopped rather than start a tunnel that iOS would refuse. Usually the “\(ShortcutRunner.cellularModeName)” shortcut is missing, renamed, or was cancelled. Set it up again — or turn Airplane Mode on yourself, teleport, then turn it back off."),
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
            // SAY IT, don't just leave a card. This is the one outcome where the user is sitting with
            // no signal and no idea why, and a banner they have to notice is not enough — the whole
            // point of the alert is that it is in front of them with the gesture spelled out. The
            // teleport's own verdict waits; a phone with no calls beats a pin that didn't take.
            LogManager.shared.addInfoLog("Cellular Mode: signal did NOT come back — leaving the Airplane Mode card up")
            reset()
            failure = Failure(
                title: L("cellular.fail.nosignal.title", fallback: "Turn Airplane Mode off yourself"),
                message: L("cellular.fail.nosignal.body",
                           fallback: "Wander asked for Airplane Mode to go back off and can't see your signal return. Swipe down from the top-right corner of the screen and tap the airplane icon. Your location stays where you set it."),
                offerSetup: false)
            return
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
        sawAirplaneOk = false
        sawLegacyShortcut = false
        hasAttemptedRecovery = false
        target = nil
        radioIsOff = false
        pendingOutcome = nil
    }
}
