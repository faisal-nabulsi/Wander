//
//  CellularModeBanner.swift
//  Wander
//
//  ══ WHY THIS CARD IS UNCONDITIONAL, AND WHY NOBODY SHOULD PUT THE AUTOMATION BACK ══
//
//  Cellular Mode used to turn Airplane Mode ON, do its work, and turn it back OFF. That last step
//  is outside this app's control, and an interrupted run never reached it — so the phone was left
//  offline with no explanation anywhere on screen. Three rounds of review tried to close that with
//  a detector: watch for "no network path at all" while a run is outstanding, wait out a grace
//  period, then explain. Every round the next review found the detector unreliable, and every one
//  of those findings was real:
//
//    • `wander://cellular-missing` (x-error) cleared the marker — and Shortcuts fires x-error for
//      ANY run failure, so the safety net disarmed itself in the exact case it existed for.
//    • The arming fallback read `@Published` mirrors that only update when `NWPathMonitor` hops to
//      the main actor: timing-dependent.
//    • It was gated on a readiness flag only set after the user tapped "I have added it", so
//      importing the shortcut and running it directly armed nothing at all.
//    • And the wall underneath all three: iOS exposes NO API to read Airplane Mode. "No network
//      path" is equally a lift, a basement, or a carrier dropping out mid-run, so the title had to
//      be hedged to "may have left Airplane Mode on" — a warning that cannot commit to its own
//      claim, shown to someone with no way to check it.
//
//  The design was asking for a fact iOS will not give us, so the fix was to stop needing it. THE
//  SHORTCUT NO LONGER TURNS AIRPLANE MODE BACK OFF. It turns it on, connects, teleports, and
//  returns. There is no trailing step for an interruption to skip, so the phone's state after any
//  outcome — success, cancel, force-quit, crash — is identical: Airplane Mode on. This card then
//  asserts something that is simply TRUE BY CONSTRUCTION: we turned Airplane Mode on and we did not
//  turn it off. No probe, no grace window, no timing, no confusion with a basement.
//
//  ONE SWIPE AND A TAP IS A WORSE RITUAL THAN NONE. That trade is deliberate: a ritual the user
//  KNOWS about beats one they discover by finding their phone offline with no explanation. If you
//  are here to re-add the automatic restore, re-read the four findings above first — they are what
//  the automation costs.
//
//  TWO CARDS, TWO QUESTIONS. "Is the radio back?" and "did the teleport work?" used to be answered
//  by the same signal, because the run finishing meant both. It no longer does, so they are
//  separate cards with separate dismissals and can be on screen together.
//
//  NOTHING HERE IS GATED ON `NetworkReachability.isOnCellular`. That flag is FALSE in Airplane Mode,
//  and gating on it is what once hid the app's only mention of Airplane Mode at exactly the moment
//  it was owed. Nothing here toggles anything either — iOS gives an app no Airplane Mode API; this
//  explains, points at the two places the switch actually lives, and waits for a tap.
//

import SwiftUI
import UIKit

struct CellularModeBanner: View {
    @ObservedObject private var run = CellularModeRun.shared
    @State private var showPaywall = false

    var body: some View {
        // A VStack rather than an either/or: a run can finish, fail to set a location, AND have left
        // the radio off. Both cards then have something to say, and the airplane one goes first
        // because it is the one costing the user calls and data right now.
        VStack(spacing: 10) {
            if run.airplaneModeLeftOn { airplaneCard }
            if run.finishedWithoutSpoof { failedCard }
        }
        // Clears the status bar / nav chrome, matching the other top banners on this screen. Lives on
        // the stack rather than on each card so two of them don't inherit 52pt of gap between them.
        .padding(.top, 52)
        .animation(.easeInOut(duration: 0.25), value: run.airplaneModeLeftOn)
        .animation(.easeInOut(duration: 0.25), value: run.finishedWithoutSpoof)
        .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
    }

    // MARK: - Airplane Mode is on

    /// NOT HEDGED, because there is nothing left to hedge. The old copy said "may have left Airplane
    /// Mode on" — it had to, because it was guessing from the absence of a network. This one is
    /// reporting: the shortcut told us it flipped the switch, and the shortcut has no step that
    /// flips it back.
    ///
    /// Control Center is named FIRST and the button is second, because a swipe from the top-right
    /// corner is genuinely faster than leaving Wander for Settings. The button exists for people who
    /// do not know that gesture, or whose Control Center is rearranged.
    private var airplaneCard: some View {
        card(icon: "airplane",
             tint: Wander.caution,
             title: L("cellular.airplane.title",
                      fallback: "Airplane Mode is on"),
             body: L("cellular.airplane.body",
                     fallback: "Cellular Mode switched it on so the tunnel could connect, and leaves it on — putting it back is the one step you do yourself. Swipe down from the top-right corner and tap the airplane. Your location stays where you set it.")) {
            Button(L("cellular.airplane.settings", fallback: "Turn it off in Settings")) {
                openAirplaneSettings()
                // Tapping this IS the user saying "I'm dealing with it", and they are about to leave
                // Wander to do it. Leaving the card up to greet them on their return would be
                // nagging about something they just handled.
                run.dismissAirplaneNotice()
            }
            .buttonStyle(.borderedProminent)
            .tint(Wander.brand)
            .controlSize(.small)

            Button(L("cellular.airplane.done", fallback: "Done")) { run.dismissAirplaneNotice() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Finished, but nothing is simulating

    private var failedCard: some View {
        card(icon: "exclamationmark.triangle.fill",
             tint: Wander.caution,
             title: L("cellular.failed.title", fallback: "Cellular Mode finished, but nothing is simulating"),
             body: L("cellular.failed.body",
                     fallback: "The run reached the end, but the tunnel or the teleport didn't take, so no location is being simulated yet. Trying again usually does it.")) {
            if run.lastRequestedCoordinate != nil {
                Button(L("cellular.failed.retry", fallback: "Try again")) { retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(Wander.brand)
                    .controlSize(.small)
            }

            Button(L("action.dismiss", fallback: "Dismiss")) { run.dismissFinishedNotice() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Actions

    /// Re-run the SAME pin. Re-gated, because the failed run never charged the trial — see
    /// `CellularModeRun.isAllowedToStart`, which is the same predicate the Simulate button uses.
    ///
    /// Note that this does NOT clear the airplane card: a retry turns Airplane Mode on again (it is
    /// already on, so the shortcut's step is a no-op), and the radio is no more restored after this
    /// run than after the last one.
    private func retry() {
        guard let coord = run.lastRequestedCoordinate else { return }
        guard CellularModeRun.isAllowedToStart else {
            showPaywall = true
            return
        }
        run.dismissFinishedNotice()
        CellularModeRun.shared.noteLaunchedFromApp(latitude: coord.latitude, longitude: coord.longitude)
        ShortcutRunner.runCellularMode(latitude: coord.latitude, longitude: coord.longitude)
    }

    /// Best-effort jump to the Airplane Mode row. `app-prefs` is already declared in
    /// LSApplicationQueriesSchemes (it is how the Shortcuts pane is reached in
    /// `CellularModeSetupView`), and if iOS refuses it we fall back to the app's own Settings page
    /// rather than doing nothing. Control Center is the faster route either way, which is why the
    /// copy names it first instead of relying on this button.
    private func openAirplaneSettings() {
        if let u = URL(string: "App-Prefs:root=AIRPLANE_MODE"), UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
        } else if let u = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(u)
        }
    }

    // MARK: - Shell

    @ViewBuilder
    private func card<Buttons: View>(icon: String,
                                     tint: Color,
                                     title: String,
                                     body: String,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { buttons() }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
