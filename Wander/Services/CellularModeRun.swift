//
//  CellularModeRun.swift
//  Wander
//
//  THE BOOKKEEPING FOR CELLULAR MODE — two facts, no inference.
//
//  READ `CellularModeBanner.swift` FIRST. It carries the reasoning for why this file is as small as
//  it is, and why nothing in it may grow back into a detector.
//
//  What it holds:
//
//   1. `airplaneModeLeftOn` — set when Wander has SEEN the radio go off: it asked for Airplane Mode,
//      then watched both transports disappear (`CellularModeSequence.confirmRadioOffThenWork`).
//      Cleared when Wander watches the signal come back, or by the user tapping the card. Persisted,
//      because the case that matters most is a run that died and an app that was force-quit: the
//      fact has to survive a relaunch.
//   1b. `legacyShortcutDetected` — the OLD all-in-one shortcut answered to the name Cellular Mode
//      now uses, so this phone has two shortcuts sharing one name and the old one has to go.
//      Persisted and sticky: it disables the feature until a verification proves the name resolves
//      to the right file again.
//
//  WHAT WENT WITH THE OLD ALL-IN-ONE SHORTCUT. A `finishedWithoutSpoof` flag, the "Cellular Mode
//  finished, but nothing is simulating" card, and the remembered pin its "Try again" button used.
//  They existed because an App Intent's return value is not surfaced during an UNATTENDED run, so a
//  shortcut-conducted run that failed and one that worked looked identical from the user's side.
//  Wander conducts the run now and reports the teleport's real outcome as it happens
//  (`CellularModeSequence.finish`), so the card had nothing left to say — and the only thing that
//  still set it was the retired shortcut's own callback. A card that can no longer appear reads like
//  a safety net without being one, which is worse than not having it.
//
//  WHAT USED TO BE HERE AND IS DELIBERATELY GONE. Three review rounds' worth of "stranding
//  detection" — `isStranded`, `hasNoNetworkAtAll`, a 45 s grace window, a 5 s ticker, a 15-minute
//  expiry, and an `armForTunnelIntent` that guessed from `NWPathMonitor`'s transport flags. All of
//  it existed to answer "is the user stranded in Airplane Mode?" from OUTSIDE a run, which iOS gives
//  an app no way to answer: there is no Airplane Mode API, and "no network path at all" is equally a
//  lift, a basement, or a carrier dropping out. Nothing here has to guess any more, because Wander
//  conducts the sequence itself: it issues each command and then watches the result, so every fact
//  above is something it observed rather than inferred. Do not re-add a probe here.
//
//  IT NEVER TOGGLES ANYTHING. It cannot: iOS gives an app no Airplane Mode API. Every action the
//  card offers still requires a tap.
//

import Foundation

@MainActor
final class CellularModeRun: ObservableObject {
    static let shared = CellularModeRun()

    private enum Keys {
        /// "A Cellular Mode run turned Airplane Mode on and the user has not told us they turned it
        /// back off." Persisted so a force-quit between the switch and the explanation cannot swallow
        /// the explanation.
        static let airplaneLeftOn = "cellularMode.airplaneLeftOn"
        /// "The old all-in-one shortcut answered to the name Cellular Mode runs." Persisted for the
        /// same reason: the run that discovered it is exactly the kind of run that gets interrupted,
        /// and the warning is worth more than the run was.
        static let legacyDetected = "cellularMode.legacyShortcutDetected"
    }

    /// So a view can watch the collision flag with `@AppStorage` without duplicating the string.
    static let legacyDetectedDefaultsKey = Keys.legacyDetected

    // MARK: - Published state

    /// Drives the Airplane Mode card. TRUE BY OBSERVATION, not by inference: the only thing that sets
    /// it is Wander asking for Airplane Mode and then watching both network transports disappear.
    @Published private(set) var airplaneModeLeftOn: Bool

    /// Drives the collision card. TRUE BY POSITIVE PROOF: the old all-in-one shortcut opened
    /// `wander://cellular-done`, which nothing Wander ships opens any more — or it turned the radio
    /// off during a check that asked for the radio to go off, which our file cannot do on any input.
    ///
    /// Sticky on purpose. While it is true, `CellularModeSequence.start` refuses to run, because the
    /// alternative is a name that may reach either file and a phone that may be left with no signal.
    /// Only a verification that gets `wander://airplane-ok` back clears it automatically.
    @Published private(set) var legacyShortcutDetected: Bool

    private init() {
        // A flag surviving from a previous launch is precisely the case this exists for — the run
        // died, the app was force-quit, and the phone is still in Airplane Mode.
        airplaneModeLeftOn = UserDefaults.standard.bool(forKey: Keys.airplaneLeftOn)
        legacyShortcutDetected = UserDefaults.standard.bool(forKey: Keys.legacyDetected)
    }

    // MARK: - Gate
    //
    /// The paywall gate for a Cellular Mode run.
    ///
    /// Deliberately the SAME predicate as the plain Simulate button
    /// (`MapSelectionView.simulate()`: `License.shared.isLicensed || TrialManager.shared.canUse(.teleport)`),
    /// because Cellular Mode IS a teleport — it just performs an Airplane Mode dance around one — and
    /// a second way to reach the same engine that skips the till is a hole, not a feature.
    ///
    /// It is a new helper rather than an edit to `simulate()` because that path must stay untouched;
    /// if the predicate there ever changes, this is the other place to change.
    static var isAllowedToStart: Bool {
        License.shared.isLicensed || TrialManager.shared.canUse(.teleport)
    }

    // MARK: - Signals in

    /// The radio has just gone off. Raise the card, and keep the fact across launches.
    ///
    /// Reached from `CellularModeSequence`, which asked for Airplane Mode and then watched both
    /// transports vanish — an observation, not a claim by the shortcut and not a guess from an idle
    /// app. The Wi-Fi path never reaches this, because it never asks for Airplane Mode at all.
    ///
    /// It is armed the moment the radio goes off rather than at the end of a run, on purpose: an
    /// interruption between here and the restore is exactly the case the card exists for, and the
    /// restore retires the card by calling `dismissAirplaneNotice` once the signal is seen to return.
    ///
    /// Idempotent: running the shortcut twice just re-asserts the same fact.
    func noteAirplaneModeTurnedOn() {
        UserDefaults.standard.set(true, forKey: Keys.airplaneLeftOn)
        if !airplaneModeLeftOn { airplaneModeLeftOn = true }
    }

    /// The old all-in-one shortcut answered to the name Cellular Mode runs.
    func noteLegacyShortcutDetected() {
        UserDefaults.standard.set(true, forKey: Keys.legacyDetected)
        if !legacyShortcutDetected { legacyShortcutDetected = true }
    }

    /// Retire the collision warning. Called on a verification that proved the name now resolves to the
    /// one-action file, and by the user dismissing the card — which is a claim about their own library
    /// ("I deleted it"), and is therefore allowed to be wrong: the next run re-detects the collision
    /// from the same positive evidence, before it can strand anyone.
    func clearLegacyShortcutNotice() {
        UserDefaults.standard.set(false, forKey: Keys.legacyDetected)
        if legacyShortcutDetected { legacyShortcutDetected = false }
    }

    // MARK: - Signals out

    /// The radio is back, or the user has read the card and tapped it away.
    ///
    /// Called automatically by `CellularModeSequence` when it asks for the radio back and then WATCHES
    /// a transport return — that is an observation, not a guess, and it is the only automatic caller.
    /// Everything else is the user's own tap, which is the right signal for a switch this app cannot
    /// see.
    func dismissAirplaneNotice() {
        UserDefaults.standard.set(false, forKey: Keys.airplaneLeftOn)
        if airplaneModeLeftOn { airplaneModeLeftOn = false }
    }
}
