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
//  The design was asking for a fact iOS will not give us from OUTSIDE a run, so the fix was to stop
//  needing it: Wander conducts the sequence itself now. It issues the "on" command and then watches
//  both transports disappear before it believes the radio went off, and it issues the "off" command
//  and watches a transport return before it believes the radio came back. Every one of the four
//  findings above is about inferring the radio's state while a Shortcut ran unattended, and none of
//  them survives an app that gave the order and is on screen watching the result.
//
//  ⚠️ AN EARLIER VERSION OF THIS COMMENT SAID "THE SHORTCUT NO LONGER TURNS AIRPLANE MODE BACK OFF".
//  That was true of one intermediate design and is not true of anything that shipped. It is corrected
//  here because it was read as the danger model by a later change and sent it looking for the wrong
//  bug: `CellularModeSequence.restoresRadioAutomatically` is TRUE, Wander runs the restore leg
//  itself, and the retired all-in-one shortcut restored the radio too — unconditionally, on every
//  path. This card is not "we left it on forever"; it is armed the moment the radio is CONFIRMED off
//  and retired the moment the signal is CONFIRMED back, so what it really marks is the window in
//  between, which is exactly where an interruption strands somebody.
//
//  THREE CARDS, THREE QUESTIONS. "Is the radio back?", "does this phone have two shortcuts sharing
//  one name?", and — until it was retired with the shortcut that raised it — "did the teleport
//  work?". They are separate cards with separate dismissals and can be on screen together.
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

    var body: some View {
        // A VStack rather than an either/or: a phone can be in Airplane Mode AND be the phone with two
        // shortcuts sharing a name — in fact that pair is the likeliest way to see either card. The
        // airplane one goes first because it is the one costing the user calls and data right now.
        VStack(spacing: 10) {
            if run.airplaneModeLeftOn { airplaneCard }
            if run.legacyShortcutDetected { collisionCard }
        }
        // Clears the status bar / nav chrome, matching the other top banners on this screen. Lives on
        // the stack rather than on each card so two of them don't inherit 52pt of gap between them.
        .padding(.top, 52)
        .animation(.easeInOut(duration: 0.25), value: run.airplaneModeLeftOn)
        .animation(.easeInOut(duration: 0.25), value: run.legacyShortcutDetected)
    }

    // MARK: - Airplane Mode is on

    /// NOT HEDGED, because there is nothing left to hedge. The old copy said "may have left Airplane
    /// Mode on" — it had to, because it was guessing from the absence of a network. This one is
    /// reporting: Wander asked for Airplane Mode and then watched both transports go away.
    ///
    /// IT MEANS "we have not yet seen your signal come back", not "we are never putting it back".
    /// Wander runs the restore leg itself and retires this card the moment a transport returns, so
    /// what is on screen here is an interrupted run — or a restore still in flight.
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
                     fallback: "Cellular Mode switched it on so the tunnel could connect, and Wander hasn't seen your signal come back yet. Swipe down from the top-right corner of the screen and tap the airplane icon. Your location stays where you set it — keep Wander open and the tunnel connected.")) {
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

    // MARK: - Two shortcuts, one name

    /// THE CARD THAT MAKES THE RENAME SAFE. Cellular Mode's shortcut is published as "Wander Cellular
    /// Mode" — the name the OLD all-in-one file was also published under — and Shortcuts is invoked by
    /// name, so a library holding both gives iOS a choice Wander cannot see or influence.
    ///
    /// This is not a warning about something that might be true. It is raised only on positive proof:
    /// the old file opened `wander://cellular-done`, which nothing Wander ships opens any more, or it
    /// turned the radio off during a check that asked for the radio to go OFF, which the shipped file
    /// cannot do on any input. Until it is cleared, `CellularModeSequence.start` refuses to run — so
    /// the feature is off rather than dangerous.
    private var collisionCard: some View {
        card(icon: "square.on.square.dashed",
             tint: Wander.caution,
             title: L("cellular.collision.title", fallback: "Two shortcuts share one name"),
             body: L("cellular.collision.body",
                     fallback: "An older Wander shortcut is also called “\(ShortcutRunner.cellularModeName)”, and iOS decides which one runs. The old one switches Airplane Mode on by itself, so Cellular Mode is switched off until it's gone. Open Shortcuts, press and hold the LONG one — the one with Wander actions inside it — and tap Delete. If your signal is off right now, swipe down from the top-right corner and tap the airplane.")) {
            Button(L("cellular.collision.open", fallback: "Open Shortcuts")) {
                ShortcutRunner.openShortcutsApp()
            }
            .buttonStyle(.borderedProminent)
            .tint(Wander.brand)
            .controlSize(.small)

            // "I deleted it" — a claim about their own library, and allowed to be wrong. The next run
            // is gated on a fresh verification anyway, so a premature tap costs a re-check, not a
            // signal.
            Button(L("cellular.collision.done", fallback: "I deleted it")) {
                run.clearLegacyShortcutNotice()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

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
