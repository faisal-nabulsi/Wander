//
//  CellularModeStartButton.swift
//  Wander
//
//  ══ ONE DOOR TO CELLULAR MODE, USED BY THREE TABS. ══
//
//  Cellular Mode used to live only on the Teleport tab. It belongs on Route and Joystick too, for the
//  reason the whole feature exists: iOS refuses to open a NEW connection to the pairing listener while
//  mobile data is the only transport, but an ESTABLISHED session keeps working indefinitely — so the
//  Airplane cycle only has to happen ONCE, at the start, and whatever movement engine follows then
//  runs normally over the session it birthed.
//
//  WHY THIS IS A COMPONENT AND NOT THREE COPIES, and it is not a style argument. The Teleport tab's
//  version is about seventy lines and every one of them is load-bearing:
//
//    • THE READINESS PAIR. `cellularModeShortcutVerified && !legacyShortcutDetected`. A tab that
//      copied this and dropped the second half would offer to run a name that the OLD all-in-one
//      shortcut also answers to — a run that turns Airplane Mode on and may never turn it back off.
//      `CellularModeSequence.start` would still refuse it, but the button would have lied about what
//      it does, which is its own kind of broken.
//    • THE PAYWALL GATE. `CellularModeRun.isAllowedToStart`, whose own comment warns that a second
//      door to this engine that skips the till is a hole. A third and fourth hand-written door is
//      exactly how that happens.
//    • THE `reachability.isOnCellular` TERM. Off cellular `start()` short-circuits the whole airplane
//      cycle and just teleports — right for Teleport, a baffling "Start route on Cellular" anywhere
//      else. The question is asked ONCE here, through the app's existing NWPathMonitor flag.
//    • THE RE-ENTRANCY DISABLE. The sequence is a singleton whose `start()` refuses a second run in
//      SILENCE, so any call site that forgets `cellularSequence.isRunning` gets a button that does
//      nothing at all with no feedback.
//
//  WHAT THE THREE TABS GENUINELY DIFFER ON is parameterised: which extra conditions make the row
//  available, which coordinate the session is born at, what the button says, and what happens once
//  the session exists.
//
//  ⚠️ THE FAILURE ALERT IS NOT IN HERE, ON PURPOSE. An alert attached to a tab that isn't visible
//  never presents, and this feature leaves the app for Shortcuts twice and can come back on a
//  different tab. It lives in `MainTabView` as a single app-wide presenter, next to
//  `CellularModeBanner`, so a Route- or Joystick-initiated failure is still heard.
//

import SwiftUI
import CoreLocation

struct CellularModeStartButton: View {
    /// Where the session is born. For Teleport that is the pin; for Route the FIRST coordinate the
    /// drive will write; for Joystick the chosen start point. Optional so a caller can render the row
    /// unconditionally and let `isOffered` decide.
    let coordinate: CLLocationCoordinate2D?
    /// The caller's own availability terms — "nothing is already running here", "a route has been
    /// previewed", and so on. ANDed with this view's transport and mode terms; it is not a substitute
    /// for them.
    let isOffered: Bool
    /// The caution note above the button, in the caller's own words (a route and a pin are not the
    /// same promise).
    let note: String
    /// The button's title once the shortcut has been verified.
    let readyLabel: String
    /// True while the caller is busy with something that must finish first.
    var isDisabled: Bool = false
    /// A SECOND allowance the caller charges separately.
    ///
    /// Cellular Mode's own gate is the TELEPORT allowance, because the run really does perform a
    /// teleport and `WanderLocationIntent.teleport` charges one. Route and Joystick then charge their
    /// own bucket when their engine starts. So for a free user a cellular route costs two trial
    /// credits — deliberate: two metered things happen, and the alternative (a route-tab button that
    /// spends a teleport credit the Route tab never asked about) is worse. Checking BOTH here is what
    /// stops the paywall arriving halfway through, after the radio has already been off for 30 s.
    var extraAllowance: () -> Bool = { true }
    /// Runs on the main actor once the session exists and the teleport landed — never on a cancel,
    /// never on a failure. This is where the route or the walk starts.
    let onEstablished: () -> Void

    @ObservedObject private var reachability = NetworkReachability.shared
    @ObservedObject private var cellularSequence = CellularModeSequence.shared

    /// Read through the SAME defaults keys `ShortcutRunner`/`CellularModeRun` write, as `@AppStorage`
    /// so the button re-labels itself the instant a check flips either one.
    @AppStorage("cellularModeShortcutVerified") private var cellularModeShortcutVerified = false
    @AppStorage(CellularModeRun.legacyDetectedDefaultsKey) private var legacyShortcutDetected = false
    @AppStorage(GslocMode.defaultsKey) private var gslocMode = false

    @State private var showPaywall = false
    @State private var showCellularSetup = false

    private var cellularModeReady: Bool { cellularModeShortcutVerified && !legacyShortcutDetected }

    /// ══ THE ROW MUST NOT VANISH OUT FROM UNDER ITS OWN SHEET, OR ITS OWN CANCEL BUTTON. ══
    ///
    /// Everything below — the note, the button, the progress line, the Cancel button, and BOTH sheets
    /// — used to live inside `if isAvailable`, and `isAvailable` is false the entire time Airplane Mode
    /// is on, which is the entire time this feature is doing its work. Two concrete failures came out
    /// of that:
    ///
    ///   • THE SETUP CARD DISMISSED ITSELF AT THE WORST MOMENT. Its "Check the shortcut" step can reach
    ///     the OLD all-in-one file, which turns Airplane Mode ON. `isOnCellular` flips false, the row
    ///     leaves the hierarchy, and the sheet goes with it — so the card that spells out the Control
    ///     Center gesture disappears exactly when the user has no signal and needs it. Joining Wi-Fi
    ///     mid-setup (plausible: step 2 is downloading a file) did the same thing.
    ///   • THERE WAS NO WAY TO CANCEL A RUN. The status line and Cancel are the only per-tab feedback
    ///     this feature has on Route and Joystick, and they were gone for the whole ~30 s run.
    ///
    /// `isOffered` is just as volatile: Route and Joystick both include `!session.isActive` in it, and
    /// the run's own teleport makes the session active partway through. So the pin covers both terms.
    private var isPinned: Bool {
        showCellularSetup || showPaywall || cellularSequence.isRunning
    }

    /// True only where Cellular Mode is the actual answer.
    private var isAvailable: Bool {
        isOffered
        && coordinate != nil
        && reachability.isOnCellular
        // gs-loc pushes through Shadowrocket's proxy, not the developer tunnel. Airplane Mode would
        // tear that proxy down, i.e. this would break PoGo mode rather than fix it. Stated here rather
        // than relying on being nested inside some caller's disabled Group — a dimmed control that is
        // still wrong is not a gate.
        && !gslocMode
    }

    var body: some View {
        // A `Group` so the two sheets attach ONCE, outside the condition, and survive `isAvailable`
        // going false. (Applying a `.sheet` to a Group with SEVERAL children applies it to every one
        // of them — two live presentations on one Bool — so the single child below is load-bearing.)
        Group {
            if isAvailable || isPinned {
                VStack(spacing: MapModeChrome.rowSpacing) {
                    offerRow
                    statusRow
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
        .sheet(isPresented: $showCellularSetup) { CellularModeSetupView() }
    }

    @ViewBuilder private var offerRow: some View {
        if isAvailable, let coord = coordinate {
            VStack(spacing: MapModeChrome.rowSpacing) {
                WanderPanelNote(status: .caution, text: note,
                                icon: "antenna.radiowaves.left.and.right")
                Button {
                    guard cellularModeReady else {
                        showCellularSetup = true
                        return
                    }
                    guard CellularModeRun.isAllowedToStart, extraAllowance() else {
                        showPaywall = true
                        return
                    }
                    // ══ WHAT THE USER WANTED WHEN THEY TAPPED, CHECKED AGAIN WHEN IT FIRES. ══
                    //
                    // `onEstablished` is stashed on a singleton at TAP time and runs about thirty
                    // seconds later, after two trips out to Shortcuts. Everything the button's own
                    // availability said at the tap can have changed by then, and two of those changes
                    // matter enough to refuse the hand-off:
                    //
                    //   • A STOP OR PANIC. `stopGeneration` is bumped by `markStopped()` and
                    //     `stopAll()`, and every other deferred start in the app already compares it
                    //     across its await (see `TunnelStartGate.then`). Without it, Stop pressed
                    //     during the airplane cycle is followed seconds later by a drive starting —
                    //     the run the user just cancelled, restarting itself.
                    //   • ANOTHER ENGINE TOOK THE STREAM. The user can switch tabs mid-run and start
                    //     the Joystick by hand; the stashed Route hand-off would then add a SECOND
                    //     writer, which is the backward-jump that produces PoGo's "Failed to detect
                    //     location (12)". Neither tab can see the other's `@State`, so the question is
                    //     asked of the writers themselves — see `movementWriterActive`.
                    let stopEpoch = SimulationSession.shared.stopGeneration
                    CellularModeSequence.shared.start(latitude: coord.latitude,
                                                      longitude: coord.longitude) { outcome in
                        // ONLY `.ok`. A cancelled or failed run must not start a drive — the whole reason
                        // this is a real callback and not an observation of `phase` going `.idle`, which
                        // success, failure and Cancel all do.
                        guard outcome == .ok else { return }
                        guard SimulationSession.shared.stopGeneration == stopEpoch else {
                            LogManager.shared.addInfoLog(
                                "Cellular Mode: session is up, but a Stop landed during the run — not starting")
                            return
                        }
                        guard !LocationSimulationCommandQueue.movementWriterActive() else {
                            LogManager.shared.addInfoLog(
                                "Cellular Mode: session is up, but another mode is already writing — not starting a second")
                            return
                        }
                        onEstablished()
                    }
                } label: {
                    Label(cellularModeReady ? readyLabel : L("map.cellular.setup", fallback: "Set up Cellular Mode"),
                          systemImage: "airplane")
                        .font(.wanderLabel)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(Wander.brand)
                .controlSize(.large)
                .disabled(isDisabled || cellularSequence.isRunning)
                .opacity((isDisabled || cellularSequence.isRunning) ? 0.5 : 1)
            }
        }
    }

    /// Wander conducts the run, so each step can name itself as it happens — the old Shortcut-driven
    /// flow had the app in the background with nothing to say. Rendered OUTSIDE `isAvailable`, because
    /// this is the half the user needs while Airplane Mode is on and `isAvailable` is false: it carries
    /// the only Cancel button the run has.
    @ViewBuilder private var statusRow: some View {
        if let status = cellularSequence.statusText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Wander.brand)
                Text(status).wanderMicro()
                Spacer(minLength: 0)
                Button(L("action.cancel", fallback: "Cancel")) { cellularSequence.cancel() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Wander.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isAvailable, cellularModeReady {
            // HONEST NUMBER. The run is a 4 s settle, up to 12 s bringing the tunnel up, up to
            // ~12 s in the teleport, and a second Shortcuts hop. Someone waiting on a call notices
            // the difference between that and "a few seconds".
            Text(localized: "map.cellular.cost",
                 fallback: "Shortcuts flashes twice, and calls and data are off for up to about 30 seconds — usually less.")
                .wanderMicro()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// ══ THE APP-WIDE HALF: EVERYTHING CELLULAR MODE HAS TO SAY, WHEREVER IT WAS STARTED. ══
///
/// Attached once, in `MainTabView`. Two alerts live here rather than on a tab:
///
///   1. THE RUN FAILED. A run bounces the app out to Shortcuts twice and can come back with a
///      different tab selected, so an alert owned by the tab that started it may never present. It
///      used to live on the Teleport tab, which was fine while that was the only entry point.
///   2. THE STOP DIDN'T TAKE. Stop exists on all three tabs, and this one has to be heard: the
///      device is still reporting the simulated location and the user believes it is not.
struct CellularModeAlerts: ViewModifier {
    @ObservedObject private var cellularSequence = CellularModeSequence.shared
    @ObservedObject private var spoofLoss = SpoofLossReporter.shared

    @AppStorage("cellularModeShortcutVerified") private var cellularModeShortcutVerified = false
    @AppStorage(CellularModeRun.legacyDetectedDefaultsKey) private var legacyShortcutDetected = false

    @State private var showPaywall = false
    @State private var showCellularSetup = false

    private var cellularModeReady: Bool { cellularModeShortcutVerified && !legacyShortcutDetected }

    func body(content: Content) -> some View {
        content
            // FAIL LOUDLY. Every way a run can go wrong — Shortcuts missing, the radio never
            // switching, the tunnel or teleport failing — surfaces as a sentence about what happened,
            // with the manual route named in the copy. `offerSetup` separates "that didn't work" from
            // "the shortcut isn't installed": only the second sends the user to the setup card.
            .alert(cellularSequence.failure?.title ?? "",
                   isPresented: Binding(get: { cellularSequence.failure != nil },
                                        set: { if !$0 { cellularSequence.failure = nil } })) {
                if cellularSequence.failure?.offerSetup == true {
                    Button(L("map.cellular.fix", fallback: "Set up Cellular Mode")) {
                        cellularSequence.failure = nil
                        showCellularSetup = true
                    }
                }
                Button(L("action.ok", fallback: "OK"), role: .cancel) { cellularSequence.failure = nil }
            } message: {
                Text(cellularSequence.failure?.message ?? "")
            }
            // ── THE DEVICE REFUSED THE STOP. IT IS STILL SPOOFING, AND ONLY THE USER CAN FIX IT. ──
            //
            // Raised only on cellular, where it is unrecoverable in process: the session that carried
            // the stop is dead and iOS will not let a replacement be born on mobile data. The action
            // is a full Cellular Mode run at the coordinate the device is STUCK at — which
            // re-establishes a session while the radio is off — followed immediately by a real stop
            // over that session. That is not a workaround; it is the only sequence that can work.
            .alert(
                LocationSimulationOutcome.stopRefusedTitle,
                isPresented: Binding(get: { spoofLoss.loss?.kind == .stopDidNotClear },
                                     set: { if !$0 { spoofLoss.acknowledge() } }),
                presenting: spoofLoss.loss
            ) { loss in
                if let target = loss.target, cellularModeReady {
                    Button(L("stop.refused.action.cellular", fallback: "Clear it with Cellular Mode")) {
                        spoofLoss.acknowledge()
                        guard CellularModeRun.isAllowedToStart else {
                            showPaywall = true
                            return
                        }
                        CellularModeSequence.shared.start(latitude: target.latitude,
                                                          longitude: target.longitude) { outcome in
                            // The session exists again, so a stop can finally be delivered. Only on
                            // `.ok`: a cancelled or failed run has nothing to stop over, and calling
                            // stopAll() there would raise a second failed-stop report.
                            guard outcome == .ok else { return }
                            SimulationSession.shared.stopAll()
                        }
                    }
                } else if loss.target != nil {
                    Button(L("spoof.lost.action.setup", fallback: "Set up Cellular Mode")) {
                        spoofLoss.acknowledge()
                        showCellularSetup = true
                    }
                }
                Button(L("action.ok", fallback: "OK"), role: .cancel) { spoofLoss.acknowledge() }
            } message: { loss in
                Text(LocationSimulationOutcome.stopRefusedMessage(onCellular: loss.needsCellularRecovery))
            }
            .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
            .sheet(isPresented: $showCellularSetup) { CellularModeSetupView() }
    }
}
