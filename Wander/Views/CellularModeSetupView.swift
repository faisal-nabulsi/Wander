//
//  CellularModeSetupView.swift
//  Wander
//
//  Onboarding for CELLULAR MODE: the one-tap sequence that gets a spoof set on mobile data with no
//  Wi-Fi.
//
//  THE BEHAVIOUR IT AUTOMATES (confirmed on device, build 139). lockdownd refuses the developer-tunnel
//  connection while the device has cellular and NO Wi-Fi *at connect time*, and it does NOT re-evaluate
//  an already-established session. So: Airplane Mode ON → connect + set the location → Airplane Mode
//  OFF, and the spoof HOLDS with cellular back on. The toggle is needed for the moment the connection
//  is made and for nothing else.
//
//  WHY IT'S A SHORTCUT AND NOT A BUTTON. iOS gives an app no API for Airplane Mode — Shortcuts is the
//  only thing on the system that can toggle it. Wander can *run* a shortcut by name
//  (`shortcuts://x-callback-url/run-shortcut`), which is what makes it one tap; it cannot flip the
//  radio itself, and nothing here flips anything until the user taps.
//
//  ══ WHAT USED TO BE STEP 4, AND WHY IT IS GONE ══
//
//  This card used to end with "Add the two Wander actions": open the imported shortcut in the
//  Shortcuts editor, search for `Start Wander Tunnel`, add it, search for `Teleport to Place`, add it,
//  set its Place field to Shortcut Input, delete two comments. Roughly a dozen taps in an editor most
//  people have never opened, and the step that quietly ended most setups.
//
//  It existed because those two actions were App Intents, and an App Intent action serialises the
//  target app's bundle id and team id — values that are different for every install, so no downloadable
//  file could contain them. The fix was not a cleverer file. It was to stop needing one: Wander
//  conducts the sequence itself now (`CellularModeSequence`) and the shortcut is reduced to the single
//  thing an app is not allowed to do — flip the switch. That file is built entirely from Shortcuts'
//  own actions, so it carries no identity, imports ready to run, and has nothing left to edit.
//
//  Setup is now: open Shortcuts once, turn on Private Sharing, add the file, check it. Nothing in an
//  editor, and nothing to rename — the file is published under its display name, so it imports
//  already called "Wander Cellular Mode", which is what the feature is called everywhere else in this
//  app and what `ShortcutRunner` asks iOS for.
//
//  ══ WHY THE LAST STEP IS A CHECK AND NOT A TICK ══
//
//  This card used to end with "I've added it — enable one-tap", a button that set a flag because the
//  user said so. That was fine while the worst case was a wasted Shortcuts flash. It is not fine now:
//  the name this feature runs is the name the OLD all-in-one shortcut was also published under, so a
//  phone that still has that file can answer Wander's request with it — and that file turns Airplane
//  Mode on, ignores our input, and can be suspended by iOS before it turns the radio back off.
//
//  So the button runs the shortcut instead of trusting the user. It asks for "off", which on the
//  shipped file switches Airplane Mode off while it is already off — nothing happens — and the file
//  answers `wander://airplane-ok` from inside itself. That answer, and only that answer, arms the
//  feature. If the old file answers instead, Wander says so by name and tells the user what to delete.
//
//  ══ THE FALLBACK IS GONE, AND WHAT REPLACED IT ══
//
//  This card used to keep the old all-in-one shortcut one disclosure away, with a dozen taps of
//  Shortcuts-editor work, because an import can fail for reasons that are not the user's fault and a
//  working second route was worth the mess. That argument was written while the whole pack was
//  shipping UNSIGNED and imports genuinely were being refused. Every published file now carries the
//  signature, and — decisively — the fallback file is the one thing on this phone that can take
//  somebody's signal away by accident. Offering it as a remedy would be handing out the hazard.
//
//  The escape hatch is still real, it is just not a second shortcut: turn Airplane Mode on yourself,
//  teleport, turn it back off. Every failure message in `CellularModeSequence` says so.
//

import SwiftUI
import UIKit

struct CellularModeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sequence = CellularModeSequence.shared

    var body: some View {
        NavigationStack {
            List {
                // ANSWERS "AM I DONE NOW?" — the question this screen used to leave open.
                //
                // The old last sentence was "Your spoof holds." True about the radio, and read by
                // users as "you can put the phone away." It is not: the fake location lives INSIDE
                // the tunnel connection (a DVT session, connection-scoped, nothing written to the
                // phone), so closing Wander or dropping the tunnel ends the spoof instantly. Airplane
                // Mode was only ever needed to make iOS ACCEPT the connection; turning it back off
                // changes nothing about needing the connection. The "because" is stated rather than
                // implied, because "keep it open" without a reason is the kind of rule people decide
                // is superstition and ignore.
                Section {
                    Text(localized: "cellular.setup.intro",
                         fallback: "On mobile data with no Wi-Fi, iOS won't let the tunnel connect — but it stops checking once it's up. Cellular Mode turns Airplane Mode on just long enough to connect and set your location, then turns it back off. Your spoof holds — as long as the tunnel stays connected and Wander stays open, because your fake location lives in that connection and nothing is stored on your phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // FIRST, ABOVE THE STEPS, BECAUSE THE ORDER IS THE SAFETY. Adding the new file while
                // an old one of the same name is still in the library gives iOS two shortcuts to
                // choose between for every run, and Wander cannot see which one it got. Deleting
                // afterwards works too — but only after a run that could have cost the user their
                // signal, which is the run this paragraph exists to prevent.
                Section {
                    Label(L("cellular.setup.deleteold",
                            fallback: "Set Cellular Mode up before today? You already have a shortcut called “\(ShortcutRunner.cellularModeName)” — the long one with Wander actions inside it. Open Shortcuts, press and hold it, tap Delete, and do that BEFORE you add the new one. Two shortcuts with one name is the one thing that can leave your phone in Airplane Mode."),
                          systemImage: "trash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(localized: "cellular.setup.deleteold.header", fallback: "Do this first")
                }

                // Says the shape of the job before the numbered steps, because "three taps, nothing to
                // edit" is the actual news here and it should not be something you infer from the
                // absence of a fourth step.
                Section {
                    Label(L("cellular.setup.shape",
                            fallback: "Four steps, and the last one is Wander checking its own work. Nothing to edit in the Shortcuts app — the shortcut you add does one thing, and Wander drives the rest itself."),
                          systemImage: "checkmark.seal")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // HONEST NUMBER, not a comfortable one. The run is a 4 s settle, up to 12 s in
                // `WanderTunnel.ensureStarted()`, up to ~12 s in the teleport, plus the second
                // Shortcuts hop — roughly half a minute at worst, not the "few seconds" this used to
                // promise. Someone waiting on a call notices.
                Section {
                    Label(L("cellular.setup.cost",
                            fallback: "You'll see Shortcuts flash twice, and calls and data are off for up to about 30 seconds — usually less — while Wander connects and sets your location."),
                          systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(localized: "cellular.setup.cost.header", fallback: "What you'll see")
                }

                // The failure this feature actually has, named where the user meets the feature.
                Section {
                    Label(L("cellular.setup.interrupted",
                            fallback: "If you force-quit or cancel mid-run, Airplane Mode can be left on. Wander tells you and shows you how to switch it back off — you're never stuck without an explanation."),
                          systemImage: "airplane")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(localized: "cellular.setup.interrupted.header", fallback: "If it's interrupted")
                }

                step(1,
                     L("cellular.setup.step1.title", fallback: "Open Shortcuts once"),
                     L("cellular.setup.step1.hidden.detail",
                       fallback: "iOS hides the next setting completely until you've run any shortcut at least once — so just open the app. (It doesn't grey it out; it isn't there at all.)"),
                     button: (L("cellular.setup.step1.button", fallback: "Open Shortcuts"),
                              { ShortcutRunner.openShortcutsApp() }))

                // APPLE RENAMED THIS SETTING. It is "Private Sharing" now, and on iOS 18+ apps live
                // under Settings → Apps, so the path moved twice. Older iOS still says "Allow
                // Untrusted Shortcuts" under Advanced, which is why both names are here — someone
                // reading this on an older phone should still find the switch.
                //
                // The last line is the one that actually unblocks people: iOS hides the row entirely
                // until Shortcuts has run at least one shortcut, so a user who skipped step 1 goes
                // looking for a setting that is not on screen and concludes our instructions are
                // wrong. Apple does not document that behaviour anywhere; it is ours to say.
                step(2,
                     L("cellular.setup.step2.privatesharing.title", fallback: "Turn on Private Sharing"),
                     L("cellular.setup.step2.privatesharing.detail",
                       fallback: "Settings → Apps → Shortcuts → Private Sharing (needs your passcode). This lets you add a shortcut that didn't come from Apple's gallery. On older iOS the same switch is called Allow Untrusted Shortcuts, under Advanced. Can't see the row at all? Run any shortcut once, then come back — iOS hides it until you have."),
                     button: (L("cellular.setup.step2.button", fallback: "Open Settings"),
                              { openSettingsShortcuts() }))

                // NO RENAME STEP. The file is published as "Wander Cellular Mode.shortcut", and iOS
                // names an import after the downloaded filename, so it arrives already called the one
                // thing Wander looks for. Asking the user to check the name was never their job — it
                // was us publishing a kebab-cased filename and making them fix it by hand.
                step(3,
                     L("cellular.setup.step3.noname.title", fallback: "Add the shortcut"),
                     L("cellular.setup.step3.noname.detail",
                       fallback: "Tap below, then tap Add Shortcut. It arrives already named “\(ShortcutRunner.cellularModeName)” — the name Wander looks for — so there is nothing to rename and nothing inside it to fill in."),
                     button: (L("cellular.setup.step3.button", fallback: "Add “\(ShortcutRunner.cellularModeName)”"),
                              { openURLString(ShortcutRunner.cellularModeInstallURL) }))

                verifySection
            }
            // A verdict is about the check the user just ran, not about this screen. Re-opening setup
            // days later to a stale "that was the old shortcut" would be reporting history as news.
            .onAppear {
                if !sequence.isRunning { sequence.verificationResult = nil }
            }
            .navigationTitle(L("cellular.setup.title", fallback: "Cellular Mode setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.close", fallback: "Close")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Step 4: prove it, don't promise it

    @ViewBuilder
    private var verifySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("4. " + L("cellular.setup.step4.title", fallback: "Check the shortcut"))
                    .font(.subheadline.weight(.semibold))
                Text(localized: "cellular.setup.step4.detail",
                     fallback: "This runs it once with “off”, which switches Airplane Mode off while it is already off — so nothing happens to your phone. It is how Wander confirms the name reaches the right shortcut, because it can run one by name but can't see inside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // `isRunning`, not `isVerifying`: a check that reaches the old shortcut hands straight
                // over to the radio-recovery leg, and that is the moment the user most needs to see
                // that something is still happening. The sequence's own status line says which.
                if sequence.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Wander.brand)
                        Text(sequence.statusText
                             ?? L("cellular.setup.step4.running", fallback: "Checking…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } else {
                    Button(L("cellular.setup.step4.button", fallback: "Check the shortcut")) {
                        sequence.verify()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                }

                if let result = sequence.verificationResult {
                    verdict(for: result)
                }
            }
        } footer: {
            Text(localized: "cellular.setup.footer",
                 fallback: "If the button later asks you to set up again, the shortcut was renamed or deleted — re-add it and check again. Nothing here toggles Airplane Mode on its own; it only ever runs when you tap.")
        }
    }

    @ViewBuilder
    private func verdict(for result: CellularModeSequence.VerificationResult) -> some View {
        switch result {
        case .verified:
            outcome("checkmark.circle.fill", Wander.brand,
                    L("cellular.setup.verdict.ok",
                      fallback: "That's it — “\(ShortcutRunner.cellularModeName)” answered and Cellular Mode is ready. Nothing was switched."),
                    dismissAfter: true)
        case .legacyShortcut:
            // NAMED, not hinted at. This is the one verdict where the user may be holding a phone with
            // no signal, so it says what to press and what to delete rather than "something went
            // wrong". The recovery run and the banner are already handling the radio; this explains it.
            outcome("exclamationmark.triangle.fill", Wander.caution,
                    L("cellular.setup.verdict.legacy",
                      fallback: "An OLDER shortcut of the same name answered, and it switched Airplane Mode on by itself. If your signal hasn't come back: swipe down from the top-right corner and tap the airplane. Then open Shortcuts, press and hold the long “\(ShortcutRunner.cellularModeName)” that has Wander actions inside it, tap Delete, and check again."),
                    dismissAfter: false)
        case .notFound:
            outcome("questionmark.circle.fill", Wander.caution,
                    L("cellular.setup.verdict.notfound",
                      fallback: "Shortcuts has nothing called “\(ShortcutRunner.cellularModeName)”. Go back to step 3 and add it — and if the import was refused, turn on Private Sharing in step 2 first."),
                    dismissAfter: false)
        case .unrecognised:
            outcome("questionmark.circle.fill", Wander.caution,
                    L("cellular.setup.verdict.unrecognised",
                      fallback: "Something ran, but it didn't identify itself as Wander's shortcut. That usually means an older copy of it. Add it again from step 3 — the new one replaces the old — then check again."),
                    dismissAfter: false)
        }
    }

    @ViewBuilder
    private func outcome(_ icon: String, _ tint: Color, _ text: String, dismissAfter: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        // Let the tick be READ before the card goes. Dismissing the instant the callback lands would
        // make a successful check indistinguishable from the sheet closing on its own.
        .task(id: dismissAfter) {
            guard dismissAfter else { return }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func step(_ n: Int, _ title: String, _ detail: String, button: (String, () -> Void)) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(n). \(title)").font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button.0, action: button.1)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
            }
        }
    }

    private func openURLString(_ s: String) {
        if let u = URL(string: s) { UIApplication.shared.open(u) }
    }

    private func openSettingsShortcuts() {
        // BEST-EFFORT BY DESIGN, AND THE WRITTEN PATH IS THE REAL INSTRUCTION. iOS has no public way
        // to deep-link another app's Settings pane, and on iOS 18+ apps moved under Settings → Apps,
        // so the historical `App-Prefs:root=SHORTCUTS` may now land on the Settings root instead of
        // the Shortcuts pane. Both spellings are tried, then the public call — which opens WANDER's
        // own pane, not Shortcuts'. That is why step 2's text spells the full path out: wherever this
        // button drops the user, the words on the card still get them there.
        for candidate in ["App-Prefs:root=SHORTCUTS", "prefs:root=SHORTCUTS"] {
            if let u = URL(string: candidate), UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u)
                return
            }
        }
        if let u = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(u)
        }
    }
}

#Preview {
    CellularModeSetupView()
}
