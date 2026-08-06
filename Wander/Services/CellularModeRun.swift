//
//  CellularModeRun.swift
//  Wander
//
//  THE BOOKKEEPING FOR CELLULAR MODE — three facts, no inference.
//
//  READ `CellularModeBanner.swift` FIRST. It carries the reasoning for why this file is as small as
//  it is, and why nothing in it may grow back into a detector.
//
//  What it holds:
//
//   1. `airplaneModeLeftOn` — set when the shortcut TELLS us it has just turned Airplane Mode on
//      (`wander://cellular-airplane-on`, fired from inside the branch that flips the switch).
//      Cleared only by the user tapping the card. Persisted, because the case that matters most is
//      a run that died and an app that was force-quit: the fact has to survive a relaunch.
//   2. `finishedWithoutSpoof` — a run reached its last action and nothing is simulating. An App
//      Intent's return value is not surfaced during an unattended run, so without this a failed run
//      and a working one look identical from the user's side.
//   3. `lastRequestedCoordinate` — where the last Shortcut teleport was asked to go, so the failure
//      card's "Try again" retries the same place. In memory only: the card that reads it only ever
//      appears in the same app session as the run that armed it.
//
//  WHAT USED TO BE HERE AND IS DELIBERATELY GONE. Three review rounds' worth of "stranding
//  detection" — `isStranded`, `hasNoNetworkAtAll`, a 45 s grace window, a 5 s ticker, a 15-minute
//  expiry, and an `armForTunnelIntent` that guessed from `NWPathMonitor`'s transport flags. All of
//  it existed to answer "is the user stranded in Airplane Mode?", which iOS gives an app no way to
//  answer: there is no Airplane Mode API, and "no network path at all" is equally a lift, a
//  basement, or a carrier dropping out. The shortcut no longer turns Airplane Mode back off, so
//  there is no longer a window to detect — the radio's state after a run is the same whatever
//  happened, and the card can simply say so. Do not re-add a probe here.
//
//  IT NEVER TOGGLES ANYTHING. It cannot: iOS gives an app no Airplane Mode API. Every action the
//  card offers still requires a tap.
//

import Foundation
import CoreLocation

@MainActor
final class CellularModeRun: ObservableObject {
    static let shared = CellularModeRun()

    private enum Keys {
        /// "A Cellular Mode run turned Airplane Mode on and the user has not told us they turned it
        /// back off." Persisted so a force-quit between the switch and the explanation cannot swallow
        /// the explanation.
        static let airplaneLeftOn = "cellularMode.airplaneLeftOn"
    }

    // MARK: - Published state

    /// Drives the Airplane Mode card. TRUE BY CONSTRUCTION, not by inference: the only thing that
    /// sets it is the shortcut reporting, from inside the branch that flips the switch, that it has
    /// just turned Airplane Mode ON — and nothing in the shortcut turns it back off afterwards.
    @Published private(set) var airplaneModeLeftOn: Bool

    /// A run reported that it FINISHED, and nothing is simulating. Drives the "that didn't take"
    /// card, which is a separate question from the radio and gets a separate card.
    @Published private(set) var finishedWithoutSpoof = false

    /// When the last completion signal was acted on, so the second of the pair is ignored. Both
    /// normally arrive — the shortcut's own `Open URLs` and Shortcuts' x-success — milliseconds
    /// apart. Latched on TIME rather than on any marker: a run takes tens of seconds, so a few
    /// seconds is far more than the gap between the two real signals and far less than the gap
    /// between two runs.
    private var lastFinishHandledAt: Date?
    private let finishDedupeSeconds: TimeInterval = 5

    /// The pin the most recent Shortcut-driven teleport was asked for. In memory ONLY, on purpose:
    /// the single thing that reads it is the "Try again" button on the failure card, and that card
    /// is only ever raised by a completion signal arriving in this same app session. A persisted
    /// copy would buy nothing and could hand "Try again" a destination from hours ago.
    private var retryTarget: CLLocationCoordinate2D?

    private init() {
        // A flag surviving from a previous launch is precisely the case this exists for — the run
        // died, the app was force-quit, and the phone is still in Airplane Mode.
        airplaneModeLeftOn = UserDefaults.standard.bool(forKey: Keys.airplaneLeftOn)
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

    /// The shortcut has just switched Airplane Mode ON. Raise the card, and keep the fact across
    /// launches.
    ///
    /// Reached from `wander://cellular-airplane-on`, which is a BAKED action sitting immediately
    /// after `Set Airplane Mode → On` inside the shortcut's cellular branch — not a toggle the user
    /// has to remember to switch on, and not something this app works out for itself. That placement
    /// is the whole design: it fires from the one branch that flips the radio, so the Wi-Fi path
    /// (which skips the airplane steps entirely) can never raise a card that would be false, and no
    /// interruption after this point can make the card wrong, because nothing later in the run puts
    /// the radio back.
    ///
    /// Idempotent: running the shortcut twice just re-asserts the same fact.
    func noteAirplaneModeTurnedOn() {
        // A new run supersedes the previous run's verdict; the old failure card would be answering a
        // question nobody is asking any more.
        finishedWithoutSpoof = false
        UserDefaults.standard.set(true, forKey: Keys.airplaneLeftOn)
        if !airplaneModeLeftOn { airplaneModeLeftOn = true }
    }

    /// The user tapped a Cellular Mode button in Wander and we are about to hand off to Shortcuts.
    ///
    /// Records the pin so "Try again" has something to retry, and NOTHING ELSE — in particular it
    /// does not raise the card. The card is raised by the shortcut, at the instant the radio
    /// actually goes off; raising it here would assert Airplane Mode for a hand-off that iOS then
    /// refused to make, or for someone still running a copy of the shortcut that turns the radio
    /// back off for them.
    func noteLaunchedFromApp(latitude: Double, longitude: Double) {
        let c = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        if CLLocationCoordinate2DIsValid(c) { retryTarget = c }
        finishedWithoutSpoof = false
    }

    /// Where a Shortcut teleport was asked to go. Called from `TeleportIntent`, which is how a run
    /// started OUTSIDE the app (Shortcuts, Siri, the Action Button, an automation) tells us its
    /// destination — nothing else on that path knows it.
    ///
    /// Unguarded on purpose. It writes an in-memory field that is read by exactly one button, on a
    /// card that only appears after a Cellular Mode run reports completion; an ordinary Shortcut
    /// teleport landing here is harmless, and gating it would mean maintaining a notion of "is a run
    /// in flight" — the kind of state this file exists to no longer have.
    func noteRequestedCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        retryTarget = coordinate
    }

    /// A run reached its last action: the shortcut's own `wander://cellular-done`, or Shortcuts'
    /// x-success. That answers ONE question — did it work? — and deliberately not the other.
    ///
    /// ⚠️ IT DOES NOT CLEAR `airplaneModeLeftOn`, and that is not an oversight. The shortcut has no
    /// step that turns Airplane Mode back off any more, so "the run finished" and "the radio is
    /// back" are no longer the same event. Only the user can make the second one true, and only the
    /// user's tap clears the flag.
    func noteRunFinished() {
        let now = Date()
        if let last = lastFinishHandledAt, now.timeIntervalSince(last) < finishDedupeSeconds { return }
        lastFinishHandledAt = now
        // The teleport's main-actor bookkeeping lands in the same run loop as its intent returning,
        // but the URL callback can beat it by a hair. One short beat, then ask — a wrong "it didn't
        // work" is worse than a late right one.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.finishedWithoutSpoof = !SimulationSession.shared.isActive
        }
    }

    // MARK: - Signals out

    /// The pin the last Shortcut teleport was asked for, so "Try again" retries the same place.
    var lastRequestedCoordinate: CLLocationCoordinate2D? { retryTarget }

    /// The user has read the Airplane Mode card and tapped it away. This is the ONLY thing that
    /// clears the flag: the app cannot see the switch, so the user's tap is the signal.
    func dismissAirplaneNotice() {
        UserDefaults.standard.set(false, forKey: Keys.airplaneLeftOn)
        if airplaneModeLeftOn { airplaneModeLeftOn = false }
    }

    /// The user has read the "that didn't take" card. Independent of the Airplane Mode card, because
    /// they answer different questions and are dismissed at different moments.
    func dismissFinishedNotice() {
        finishedWithoutSpoof = false
    }
}
